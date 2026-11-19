#!/bin/bash
# deploy.sh로 만든 리소스 삭제 (CloudFront는 비활성화 후 삭제라 10분 이상 걸림)
set -uo pipefail
cd "$(dirname "$0")/.."
export AWS_DEFAULT_REGION=ap-northeast-2
source infra/.deploy-output.env

echo "API Gateway / Lambda 삭제"
aws apigateway delete-rest-api --rest-api-id "$API_ID"
aws lambda delete-function --function-name "$FUNC"
aws logs delete-log-group --log-group-name "/aws/lambda/${FUNC}" 2>/dev/null
aws iam delete-role-policy --role-name "$ROLE" --policy-name cnu-chatbot-chat-least-privilege
aws iam delete-role --role-name "$ROLE"

echo "DynamoDB 삭제"
aws dynamodb delete-table --table-name "$TABLE" >/dev/null

echo "CloudFront 비활성화 후 삭제"
ETAG=$(aws cloudfront get-distribution-config --id "$DIST_ID" --query ETag --output text)
aws cloudfront get-distribution-config --id "$DIST_ID" --query DistributionConfig > /tmp/cfg.json
OAC_ID=$(python3 -c "import json;print(json.load(open('/tmp/cfg.json'))['Origins']['Items'][0]['OriginAccessControlId'])")
python3 -c "import json;c=json.load(open('/tmp/cfg.json'));c['Enabled']=False;json.dump(c,open('/tmp/cfg.json','w'))"
aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" --distribution-config file:///tmp/cfg.json >/dev/null
aws cloudfront wait distribution-deployed --id "$DIST_ID"
ETAG=$(aws cloudfront get-distribution --id "$DIST_ID" --query ETag --output text)
aws cloudfront delete-distribution --id "$DIST_ID" --if-match "$ETAG"
OETAG=$(aws cloudfront get-origin-access-control --id "$OAC_ID" --query ETag --output text)
aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$OETAG"

echo "S3 버킷 비우고 삭제 (문서 버킷은 버전까지 삭제)"
aws s3 rm "s3://${WEB_BUCKET}" --recursive >/dev/null
aws s3api delete-bucket --bucket "$WEB_BUCKET"
aws s3api list-object-versions --bucket "$DOCS_BUCKET" --output json \
  --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]}' > /tmp/versions.json
aws s3api delete-objects --bucket "$DOCS_BUCKET" --delete file:///tmp/versions.json >/dev/null
aws s3api delete-bucket --bucket "$DOCS_BUCKET"
echo "정리 완료"
