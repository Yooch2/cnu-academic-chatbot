# 충남대 학사 안내 챗봇 (cnu-academic-chatbot)

클라우드 아키텍처 수업 프로젝트입니다. 학사 공지, 학칙·졸업 요건, 장학금 안내 같은 학교 공개 문서를 근거로
학생 질문에 답하고 출처를 같이 보여 주는 RAG 챗봇을 AWS 위에 만드는 것이 목표입니다.

- 1주차: 서비스 기획과 AWS 아키텍처 설계 → [`docs/architecture.png`](docs/architecture.png)
- 2주차: AWS 환경·개발 환경 구성, 테스트 앱/API 배포 (현재 단계)

## 2주차 구성

| 구분 | 사용한 것 | 비고 |
|---|---|---|
| 웹 화면 | S3(비공개 버킷) + CloudFront(OAC) | 버킷은 퍼블릭 액세스 차단, CloudFront로만 접근 |
| API | API Gateway(REST, `dev` 스테이지) + Lambda(Python 3.12) | `GET /health`, `POST /chat`, 초당 10건 호출 제한 |
| 문서 저장소 | S3 문서 버킷 (`raw/`, `processed/`) | 버전 관리 켬, 2주차는 예시 문서 1개만 |
| 대화 기록 | DynamoDB (온디맨드) | 질문·답변·출처 저장 |
| 권한 | Lambda 실행 역할 1개 | 로그 쓰기, 문서 버킷 `raw/` 읽기, 테이블 쓰기만 허용 |

2주차의 `/chat`은 연결 확인용이라 Bedrock 대신 **예시 문서에서 키워드로 근거를 찾아** 답합니다.
근거가 없으면 "답변하기 어렵습니다"를 돌려줍니다. 3주차부터 임베딩 + 벡터 검색 + Bedrock 생성으로 바꿀 예정입니다.

## 폴더 구조

```
frontend/        웹 화면 (index.html, app.js, style.css) - config.js는 배포 때 생성
backend/chat/    질문 처리 Lambda
data/            테스트용 예시 문서
infra/           deploy.sh, cleanup.sh, IAM 정책
docs/            아키텍처 구성도
```

## 배포 / 정리

AWS CLI 자격 증명이 설정된 상태에서 실행합니다 (리전: ap-northeast-2).

```bash
bash infra/deploy.sh    # 배포, 마지막에 웹 화면 주소와 API 주소 출력
bash infra/cleanup.sh   # 실습 끝나면 전부 삭제 (CloudFront 비활성화 때문에 10분 이상 걸림)
```

## 개발 환경

- macOS, VS Code, Claude Code(코드 작성 보조)
- AWS CLI v2, Python 3.12(Lambda 런타임), Git / GitHub
