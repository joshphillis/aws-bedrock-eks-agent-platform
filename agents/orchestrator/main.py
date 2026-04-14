"""
Orchestrator Agent — AWS Bedrock / EKS edition
Decomposes user tasks into sub-tasks, routes them to specialist agents via SQS.
Primary LLM: Amazon Bedrock (Claude 3.5 Sonnet)
Fallback LLM:  OpenAI GPT-4o
"""

import asyncio
import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException
from openai import AsyncOpenAI
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ── Configuration (injected from agent-secrets K8s Secret via ASCP) ──────────
AWS_REGION       = os.getenv("AWS_REGION", "us-east-1")
BEDROCK_MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "anthropic.claude-3-5-sonnet-20241022-v2:0")

SQS_RESEARCH_QUEUE_URL = os.getenv("SQS_RESEARCH_QUEUE_URL", "")
SQS_ANALYSIS_QUEUE_URL = os.getenv("SQS_ANALYSIS_QUEUE_URL", "")
SQS_WRITER_QUEUE_URL   = os.getenv("SQS_WRITER_QUEUE_URL", "")
SQS_RESULTS_QUEUE_URL  = os.getenv("SQS_RESULTS_QUEUE_URL", "")
OPENAI_API_KEY         = os.getenv("OPENAI_API_KEY", "")

# ── AWS clients  (IRSA provides credentials automatically) ───────────────────
sqs_client     = boto3.client("sqs", region_name=AWS_REGION)
bedrock_client = boto3.client("bedrock-runtime", region_name=AWS_REGION)
openai_client  = AsyncOpenAI(api_key=OPENAI_API_KEY) if OPENAI_API_KEY else None

# ── In-memory job store (production: swap for DynamoDB / ElastiCache) ─────────
results_store: dict[str, dict[str, Any]] = {}
pending_jobs:  dict[str, set[str]]       = {}


# ── Pydantic models ───────────────────────────────────────────────────────────
class TaskRequest(BaseModel):
    prompt:  str
    context: dict[str, Any] = {}


class TaskResponse(BaseModel):
    job_id:  str
    status:  str
    message: str


class JobResult(BaseModel):
    job_id:     str
    status:     str
    results:    dict[str, Any] = {}
    created_at: str


# ── Bedrock helpers ───────────────────────────────────────────────────────────
def _invoke_bedrock_sync(system_prompt: str, user_message: str) -> str:
    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 4096,
        "temperature": 0.2,
        "system": system_prompt,
        "messages": [{"role": "user", "content": user_message}],
    })
    response = bedrock_client.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=body,
    )
    result = json.loads(response["body"].read())
    return result["content"][0]["text"]


async def _invoke_openai_fallback(system_prompt: str, user_message: str) -> str:
    if not openai_client:
        raise RuntimeError("OpenAI fallback not configured — OPENAI_API_KEY is empty")
    resp = await openai_client.chat.completions.create(
        model="gpt-4o",
        temperature=0.2,
        response_format={"type": "json_object"},
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user",   "content": user_message},
        ],
    )
    return resp.choices[0].message.content


async def decompose_task(prompt: str) -> dict:
    system_prompt = (
        "You are an orchestrator AI. Decompose the user request into specialist sub-tasks. "
        "Return ONLY valid JSON with these keys:\n"
        '{\n'
        '  "research_task": "<what to research, or null>",\n'
        '  "analysis_task": "<what to analyse, or null>",\n'
        '  "writer_task":   "<what to write, or null>",\n'
        '  "reasoning":     "<brief decomposition rationale>"\n'
        '}'
    )
    loop = asyncio.get_running_loop()
    try:
        raw = await loop.run_in_executor(
            None, _invoke_bedrock_sync, system_prompt, prompt
        )
        logger.info("Bedrock decomposition succeeded")
    except (BotoCoreError, ClientError) as exc:
        logger.warning("Bedrock failed, falling back to OpenAI: %s", exc)
        raw = await _invoke_openai_fallback(system_prompt, prompt)
    return json.loads(raw)


# ── SQS helpers ───────────────────────────────────────────────────────────────
def _publish(queue_url: str, message: dict) -> None:
    sqs_client.send_message(
        QueueUrl=queue_url,
        MessageBody=json.dumps(message),
        MessageAttributes={
            "content-type": {"DataType": "String", "StringValue": "application/json"},
        },
    )


# ── Background result listener ────────────────────────────────────────────────
async def results_listener() -> None:
    logger.info("Results listener started — polling %s", SQS_RESULTS_QUEUE_URL)
    while True:
        try:
            resp = sqs_client.receive_message(
                QueueUrl=SQS_RESULTS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
                AttributeNames=["All"],
            )
            for msg in resp.get("Messages", []):
                try:
                    body       = json.loads(msg["Body"])
                    job_id     = body.get("job_id")
                    agent_type = body.get("agent_type")
                    if job_id and agent_type:
                        results_store.setdefault(job_id, {})[agent_type] = body.get("result", {})
                        pending_jobs.get(job_id, set()).discard(agent_type)
                        logger.info("Received result job=%s agent=%s", job_id, agent_type)
                    sqs_client.delete_message(
                        QueueUrl=SQS_RESULTS_QUEUE_URL,
                        ReceiptHandle=msg["ReceiptHandle"],
                    )
                except Exception as exc:
                    logger.error("Error processing result message: %s", exc)
        except Exception as exc:
            logger.error("SQS receive error: %s", exc)
            await asyncio.sleep(5)


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(results_listener())
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


# ── FastAPI application ───────────────────────────────────────────────────────
app = FastAPI(title="Orchestrator Agent", version="1.0.0", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "healthy", "service": "orchestrator"}


@app.get("/health/ready")
async def ready():
    missing = [
        name
        for name, url in {
            "SQS_RESEARCH_QUEUE_URL": SQS_RESEARCH_QUEUE_URL,
            "SQS_ANALYSIS_QUEUE_URL": SQS_ANALYSIS_QUEUE_URL,
            "SQS_WRITER_QUEUE_URL":   SQS_WRITER_QUEUE_URL,
            "SQS_RESULTS_QUEUE_URL":  SQS_RESULTS_QUEUE_URL,
        }.items()
        if not url
    ]
    if missing:
        raise HTTPException(status_code=503, detail=f"Missing env vars: {missing}")
    return {"status": "ready"}


@app.post("/tasks", response_model=TaskResponse, status_code=202)
async def create_task(request: TaskRequest):
    job_id     = str(uuid.uuid4())
    created_at = datetime.utcnow().isoformat()

    try:
        plan = await decompose_task(request.prompt)
    except Exception as exc:
        logger.error("Task decomposition failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"LLM error: {exc}")

    pending: set[str] = set()
    routing = {
        "research_task": ("research", SQS_RESEARCH_QUEUE_URL),
        "analysis_task": ("analysis", SQS_ANALYSIS_QUEUE_URL),
        "writer_task":   ("writer",   SQS_WRITER_QUEUE_URL),
    }
    for plan_key, (agent_type, queue_url) in routing.items():
        task_text = plan.get(plan_key)
        if task_text and queue_url:
            _publish(queue_url, {
                "job_id":     job_id,
                "agent_type": agent_type,
                "task":       task_text,
                "context":    request.context,
                "created_at": created_at,
            })
            pending.add(agent_type)

    pending_jobs[job_id]  = pending
    results_store[job_id] = {}

    logger.info("job=%s dispatched sub-tasks=%s", job_id, pending)
    return TaskResponse(
        job_id=job_id,
        status="pending",
        message=f"Dispatched {len(pending)} sub-tasks",
    )


@app.get("/tasks/{job_id}", response_model=JobResult)
async def get_task(job_id: str):
    if job_id not in results_store:
        raise HTTPException(status_code=404, detail="Job not found")
    remaining = pending_jobs.get(job_id, set())
    status    = "complete" if not remaining else "pending"
    return JobResult(
        job_id=job_id,
        status=status,
        results=results_store[job_id],
        created_at=datetime.utcnow().isoformat(),
    )
