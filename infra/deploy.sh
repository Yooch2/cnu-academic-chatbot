#!/bin/bash
# 2주차 테스트 환경 배포 스크립트 (서울 리전)
# 만드는 것: S3 웹 버킷 + CloudFront(OAC), S3 문서 버킷, DynamoDB 대화 기록 테이블,
#           Lambda 실행 역할(최소 권한), Lambda 함수, API Gateway REST API(dev)
set -euo pipefail
cd "$(dirname "$0")/.."

REGION=ap-northeast-2
export AWS_DEFAULT_REGION=$REGION
ACC=$(aws sts get-caller-identity --query Account --output text)
P=cnu-chatbot
WEB_BUCKET=${P}-web-${ACC}
DOCS_BUCKET=${P}-docs-${ACC}
TABLE=${P}-chatlog
ROLE=${P}-chat-lambda-role
FUNC=${P}-chat
API_NAME=${P}-api
OUT=infra/.deploy-output.env
TAG="Key=Project,Value=cnu-academic-chatbot"

echo "[1/7] S3 버킷 (퍼블릭 액세스 차단)"
for B in "$WEB_BUCKET" "$DOCS_BUCKET"; do
  aws s3api head-bucket --bucket "$B" 2>/dev/null || \
    aws s3api create-bucket --bucket "$B" --create-bucket-configuration LocationConstraint=$REGION >/dev/null
  aws s3api put-public-access-block --bucket "$B" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-tagging --bucket "$B" --tagging "TagSet=[{${TAG}}]"
done
aws s3api put-bucket-versioning --bucket "$DOCS_BUCKET" --versioning-configuration Status=Enabled
aws s3 cp data/sample_docs.json "s3://${DOCS_BUCKET}/raw/sample_docs.json" >/dev/null
aws s3api put-object --bucket "$DOCS_BUCKET" --key processed/ >/dev/null

echo "[2/7] DynamoDB 대화 기록 테이블"
aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1 || \
  aws dynamodb create-table --table-name "$TABLE" --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST --tags "$TAG" >/dev/null
aws dynamodb wait table-exists --table-name "$TABLE"

echo "[3/7] Lambda 실행 역할 (로그 + 문서 버킷 읽기 + 테이블 쓰기만)"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document file://infra/lambda-trust.json --tags "$TAG" >/dev/null
  sleep 10
fi
sed -e "s/__ACC__/${ACC}/g" -e "s/__DOCS_BUCKET__/${DOCS_BUCKET}/g" -e "s/__TABLE__/${TABLE}/g" -e "s/__FUNC__/${FUNC}/g" \
  infra/lambda-policy.json > /tmp/${P}-policy.json
aws iam put-role-policy --role-name "$ROLE" --policy-name ${P}-chat-least-privilege --policy-document file:///tmp/${P}-policy.json
ROLE_ARN=$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)

echo "[4/7] Lambda 함수"
rm -f /tmp/${P}-chat.zip && (cd backend/chat && zip -q /tmp/${P}-chat.zip lambda_function.py)
if aws lambda get-function --function-name "$FUNC" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FUNC" --zip-file fileb:///tmp/${P}-chat.zip >/dev/null
else
  for i in 1 2 3 4 5; do  # 새 역할이 퍼지기 전에는 실패할 수 있어서 재시도
    aws lambda create-function --function-name "$FUNC" --runtime python3.12 --handler lambda_function.lambda_handler \
      --role "$ROLE_ARN" --zip-file fileb:///tmp/${P}-chat.zip --timeout 10 --memory-size 128 \
      --environment "Variables={DOCS_BUCKET=${DOCS_BUCKET},CHAT_TABLE=${TABLE}}" --tags Project=cnu-academic-chatbot >/dev/null && break
    sleep 10
  done
fi
aws lambda wait function-active-v2 --function-name "$FUNC"
FUNC_ARN=$(aws lambda get-function --function-name "$FUNC" --query Configuration.FunctionArn --output text)

echo "[5/7] API Gateway REST API (GET /health, POST /chat, CORS)"
API_ID=$(aws apigateway get-rest-apis --query "items[?name=='${API_NAME}'].id | [0]" --output text)
if [ "$API_ID" = "None" ]; then
  API_ID=$(aws apigateway create-rest-api --name "$API_NAME" --endpoint-configuration types=REGIONAL --query id --output text)
  ROOT=$(aws apigateway get-resources --rest-api-id "$API_ID" --query "items[?path=='/'].id | [0]" --output text)
  URI="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${FUNC_ARN}/invocations"
  for R in health:GET chat:POST; do
    NAME=${R%%:*}; M=${R##*:}
    RID=$(aws apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT" --path-part "$NAME" --query id --output text)
    aws apigateway put-method --rest-api-id "$API_ID" --resource-id "$RID" --http-method "$M" --authorization-type NONE >/dev/null
    aws apigateway put-integration --rest-api-id "$API_ID" --resource-id "$RID" --http-method "$M" \
      --type AWS_PROXY --integration-http-method POST --uri "$URI" >/dev/null
    # 브라우저 사전 요청(OPTIONS)은 Lambda까지 가지 않고 MOCK으로 응답
    aws apigateway put-method --rest-api-id "$API_ID" --resource-id "$RID" --http-method OPTIONS --authorization-type NONE >/dev/null
    aws apigateway put-integration --rest-api-id "$API_ID" --resource-id "$RID" --http-method OPTIONS --type MOCK \
      --request-templates '{"application/json":"{\"statusCode\": 200}"}' >/dev/null
    aws apigateway put-method-response --rest-api-id "$API_ID" --resource-id "$RID" --http-method OPTIONS --status-code 200 \
      --response-parameters '{"method.response.header.Access-Control-Allow-Origin":false,"method.response.header.Access-Control-Allow-Methods":false,"method.response.header.Access-Control-Allow-Headers":false}' >/dev/null
    aws apigateway put-integration-response --rest-api-id "$API_ID" --resource-id "$RID" --http-method OPTIONS --status-code 200 \
      --response-parameters '{"method.response.header.Access-Control-Allow-Origin":"'"'*'"'","method.response.header.Access-Control-Allow-Methods":"'"'GET,POST,OPTIONS'"'","method.response.header.Access-Control-Allow-Headers":"'"'Content-Type'"'"}' >/dev/null
  done
  aws lambda add-permission --function-name "$FUNC" --statement-id apigw-invoke --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${REGION}:${ACC}:${API_ID}/*/*/*" >/dev/null
fi
aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name dev >/dev/null
# 호출 횟수 제한 (초당 10건, 순간 20건)
aws apigateway update-stage --rest-api-id "$API_ID" --stage-name dev --patch-operations \
  op=replace,path=/*/*/throttling/rateLimit,value=10 op=replace,path=/*/*/throttling/burstLimit,value=20 >/dev/null
API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/dev"

echo "[6/7] CloudFront 배포 (OAC로 웹 버킷 접근)"
DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='${P}-web'].Id | [0]" --output text 2>/dev/null || echo None)
if [ "$DIST_ID" = "None" ] || [ -z "$DIST_ID" ]; then
  OAC_ID=$(aws cloudfront create-origin-access-control --origin-access-control-config \
    "Name=${P}-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query OriginAccessControl.Id --output text)
  cat > /tmp/${P}-dist.json <<EOF
{"CallerReference":"${P}-$(date +%s)","Comment":"${P}-web","Enabled":true,"DefaultRootObject":"index.html",
 "Origins":{"Quantity":1,"Items":[{"Id":"web","DomainName":"${WEB_BUCKET}.s3.${REGION}.amazonaws.com","OriginAccessControlId":"${OAC_ID}","S3OriginConfig":{"OriginAccessIdentity":""}}]},
 "DefaultCacheBehavior":{"TargetOriginId":"web","ViewerProtocolPolicy":"redirect-to-https","CachePolicyId":"658327ea-f89d-4fab-a63d-7e88639e58f6","Compress":true,
  "AllowedMethods":{"Quantity":2,"Items":["GET","HEAD"],"CachedMethods":{"Quantity":2,"Items":["GET","HEAD"]}}},
 "PriceClass":"PriceClass_200"}
EOF
  DIST_ID=$(aws cloudfront create-distribution --distribution-config file:///tmp/${P}-dist.json --query Distribution.Id --output text)
fi
DIST_ARN="arn:aws:cloudfront::${ACC}:distribution/${DIST_ID}"
DIST_DOMAIN=$(aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.DomainName --output text)
cat > /tmp/${P}-bucket-policy.json <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"AllowCloudFrontOAC","Effect":"Allow","Principal":{"Service":"cloudfront.amazonaws.com"},
 "Action":"s3:GetObject","Resource":"arn:aws:s3:::${WEB_BUCKET}/*","Condition":{"StringEquals":{"AWS:SourceArn":"${DIST_ARN}"}}}]}
EOF
aws s3api put-bucket-policy --bucket "$WEB_BUCKET" --policy file:///tmp/${P}-bucket-policy.json

echo "[7/7] 프런트엔드 업로드"
echo "window.API_BASE_URL = \"${API_URL}\";" > frontend/config.js
aws s3 sync frontend "s3://${WEB_BUCKET}/" --delete >/dev/null

cat > "$OUT" <<EOF
WEB_BUCKET=${WEB_BUCKET}
DOCS_BUCKET=${DOCS_BUCKET}
TABLE=${TABLE}
ROLE=${ROLE}
FUNC=${FUNC}
API_ID=${API_ID}
DIST_ID=${DIST_ID}
API_URL=${API_URL}
WEB_URL=https://${DIST_DOMAIN}
EOF
echo
echo "완료 (CloudFront는 전파에 10분 정도 걸릴 수 있음)"
echo "  웹 화면 : https://${DIST_DOMAIN}"
echo "  API     : ${API_URL}/health"
