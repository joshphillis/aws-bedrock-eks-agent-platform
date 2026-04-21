"""
Analysis Agent — AWS Bedrock / EKS edition
Polls SQS analysis-tasks queue, calls Bedrock (Claude), publishes results to agent-results queue.
Primary LLM: Amazon Bedrock (Claude 3.5 Sonnet)
Fallback LLM:  OpenAI GPT-4o
"""

import asyncio
import json
import logging
import os
from contextlib import asynccontextmanager

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException
from openai import AsyncOpenAI

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ── Configuration ─────────────────────────────────────────────────────────────
AWS_REGION              = os.getenv("AWS_REGION", "us-east-1")
BEDROCK_MODEL_ID        = os.getenv("BEDROCK_MODEL_ID", "anthropic.claude-3-5-sonnet-20241022-v2:0")
SQS_ANALYSIS_QUEUE_URL  = os.getenv("SQS_ANALYSIS_QUEUE_URL", "")
SQS_RESULTS_QUEUE_URL   = os.getenv("SQS_RESULTS_QUEUE_URL", "")
OPENAI_API_KEY          = os.getenv("OPENAI_API_KEY", "")

# ── AWS clients (IRSA provides credentials) ───────────────────────────────────
sqs_client     = boto3.client("sqs", region_name=AWS_REGION)
bedrock_client = boto3.client("bedrock-runtime", region_name=AWS_REGION)
openai_client  = AsyncOpenAI(api_key=OPENAI_API_KEY) if OPENAI_API_KEY else None

SYSTEM_PROMPT = """You are an analysis specialist. Given an analysis task, apply structured reasoning
to extract insights, identify patterns, and surface actionable recommendations.
Return ONLY valid JSON with this exact structure:
{
  "key_insights":       ["<insight 1>", "<insight 2>"],
  "patterns":           ["<pattern 1>"],
  "risks":              ["<risk 1>"],
  "recommendations":    ["<recommendation 1>"],
  "confidence":         0.85
}"""


# ── LLM invocation ────────────────────────────────────────────────────────────
def _invoke_bedrock_sync(task: str) -> str:
    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 4096,
        "temperature": 0.2,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": task}],
    })
    response = bedrock_client.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=body,
    )
    return json.loads(response["body"].read())["content"][0]["text"]


async def _invoke_openai_fallback(task: str) -> str:
    if not openai_client:
        raise RuntimeError("OpenAI fallback not configured — OPENAI_API_KEY is empty")
    resp = await openai_client.chat.completions.create(
        model="gpt-4o",
        temperature=0.2,
        response_format={"type": "json_object"},
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user",   "content": task},
        ],
    )
    return resp.choices[0].message.content


async def run_llm(task: str) -> str:
    loop = asyncio.get_running_loop()
    try:
        return await loop.run_in_executor(None, _invoke_bedrock_sync, task)
    except (BotoCoreError, ClientError) as exc:
        logger.warning("Bedrock failed, using OpenAI fallback: %s", exc)
        return await _invoke_openai_fallback(task)


# ── Message processing ────────────────────────────────────────────────────────
async def process_message(body: dict) -> None:
    job_id = body.get("job_id", "unknown")
    task   = body.get("task", "")
    logger.info("Processing analysis task job=%s", job_id)

    raw    = await run_llm(task)
    result = json.loads(raw)

    loop = asyncio.get_running_loop()
    await loop.run_in_executor(
        None,
        lambda: sqs_client.send_message(
            QueueUrl=SQS_RESULTS_QUEUE_URL,
            MessageBody=json.dumps({
                "job_id":     job_id,
                "agent_type": "analysis",
                "result":     result,
            }),
        ),
    )
    logger.info("Published analysis result job=%s confidence=%s",
                job_id, result.get("confidence"))


# ── SQS polling loop ──────────────────────────────────────────────────────────
async def poll_queue() -> None:
    logger.info("Analysis agent polling %s", SQS_ANALYSIS_QUEUE_URL)
    loop = asyncio.get_running_loop()
    while True:
        try:
            resp = await loop.run_in_executor(
                None,
                lambda: sqs_client.receive_message(
                    QueueUrl=SQS_ANALYSIS_QUEUE_URL,
                    MaxNumberOfMessages=5,
                    WaitTimeSeconds=20,
                ),
            )
            for msg in resp.get("Messages", []):
                receipt_handle = msg["ReceiptHandle"]
                try:
                    await process_message(json.loads(msg["Body"]))
                except Exception as exc:
                    logger.error("Error processing message: %s", exc)
                finally:
                    await loop.run_in_executor(
                        None,
                        lambda: sqs_client.delete_message(
                            QueueUrl=SQS_ANALYSIS_QUEUE_URL,
                            ReceiptHandle=receipt_handle,
                        ),
                    )
        except Exception as exc:
            logger.error("SQS receive error: %s", exc)
            await asyncio.sleep(5)


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(poll_queue())
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


# ── FastAPI application ───────────────────────────────────────────────────────
app = FastAPI(title="Analysis Agent", version="1.0.0", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "healthy", "service": "analysis-agent"}


@app.get("/health/ready")
async def ready():
    if not SQS_ANALYSIS_QUEUE_URL or not SQS_RESULTS_QUEUE_URL:
        raise HTTPException(status_code=503, detail="SQS queue URLs not configured")
    return {"status": "ready"}
