"""충남대 학사 안내 챗봇 - 질문 처리 Lambda (2주차 테스트 버전)

2주차에는 AWS 환경이 제대로 연결됐는지 확인하는 게 목표라서
Bedrock 대신 S3에 올린 예시 문서에서 키워드로 근거를 찾아 답한다.
3주차부터 이 부분을 임베딩 + 벡터 검색 + Bedrock 생성으로 바꿀 예정.
"""
import json
import os
import re
import uuid
from datetime import datetime, timezone

import boto3

s3 = boto3.client("s3")
table = boto3.resource("dynamodb").Table(os.environ["CHAT_TABLE"])
DOCS_BUCKET = os.environ["DOCS_BUCKET"]
DOCS_KEY = os.environ.get("DOCS_KEY", "raw/sample_docs.json")

CORS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
}

_docs = None  # 같은 실행 환경에서는 한 번만 읽어 둔다


def load_docs():
    global _docs
    if _docs is None:
        body = s3.get_object(Bucket=DOCS_BUCKET, Key=DOCS_KEY)["Body"].read()
        _docs = json.loads(body)
    return _docs


def tokens(text):
    return set(re.findall(r"[가-힣A-Za-z0-9]+", text))


def search(question, docs, min_score=1):
    """질문에 들어 있는 단어가 문서 키워드와 몇 개 겹치는지로 점수를 매긴다."""
    q = tokens(question)
    scored = []
    for doc in docs:
        score = sum(1 for kw in doc["keywords"] if any(kw in w for w in q))
        if score >= min_score:
            scored.append((score, doc))
    if not scored:
        return []
    # "신청"처럼 여러 문서에 흔한 단어 하나만 겹친 문서는 출처에서 빼고, 가장 점수가 높은 문서만 쓴다
    best = max(s for s, _ in scored)
    return [d for s, d in scored if s == best][:2]


def respond(status, body):
    return {"statusCode": status, "headers": CORS, "body": json.dumps(body, ensure_ascii=False)}


def lambda_handler(event, context):
    path = event.get("resource") or event.get("path", "")
    method = event.get("httpMethod", "")

    if path == "/health" and method == "GET":
        return respond(200, {"status": "ok", "service": "cnu-academic-chatbot", "stage": "dev"})

    if path == "/chat" and method == "POST":
        try:
            question = (json.loads(event.get("body") or "{}").get("question") or "").strip()
        except json.JSONDecodeError:
            return respond(400, {"error": "JSON 형식이 올바르지 않습니다."})
        if not question:
            return respond(400, {"error": "question 값을 입력해 주세요."})

        hits = search(question, load_docs())
        if hits:
            answer = hits[0]["summary"]
            sources = [{"title": d["title"], "date": d["date"], "url": d["url"]} for d in hits]
        else:
            answer = "확인된 자료가 없어서 답변하기 어렵습니다. 학사지원 담당 부서에 문의해 주세요."
            sources = []

        table.put_item(Item={
            "id": str(uuid.uuid4()),
            "created_at": datetime.now(timezone.utc).isoformat(),
            "question": question,
            "answer": answer,
            "source_titles": [s["title"] for s in sources],
        })
        return respond(200, {"question": question, "answer": answer, "sources": sources, "mode": "keyword-test"})

    return respond(404, {"error": "지원하지 않는 경로입니다."})
