# QA-skills

QA 업무에 쓰는 Claude Code 스킬 모음.

## 스킬

### `qa-report` — 코드 로직 분석 기반 QA 리포트 작성

코드와 변경 디프를 직접 읽어 QA가 검증해야 할 위험 지점을 찾고,
실행 가능한 테스트 케이스 표가 포함된 마크다운 리포트를 만든다.

```
.claude/skills/qa-report/
├── SKILL.md                        # 작성 절차와 원칙
├── references/
│   ├── risk-checklist.md           # 스택 무관 위험 카테고리 12종 + 탐색할 코드 패턴
│   └── report-template.md          # 리포트 구조와 작성 기준
└── scripts/
    └── collect_context.sh          # 변경 파일·디프·관련 테스트 수집
```

**사용 예시**

```
이번 브랜치 변경분 QA 리포트 작성해줘
src/payment 모듈에서 QA가 확인해야 할 부분 뽑아줘
origin/main 대비 회귀 테스트 범위 알려줘
```

**산출물**: `qa-reports/QA-<YYYYMMDD>-<대상>.md`

- 요약 / 우선순위별 건수
- 변경 내용(기능 관점)
- 회귀 영향 범위 (변경된 코드의 호출 지점 추적)
- 위험 지점 상세 (코드 근거 `파일:라인` 포함)
- 발견된 결함
- 테스트 케이스 표 (사전조건 · 절차 · 기대 결과 · 근거 · 자동화 커버 여부)
- 자동화 커버리지 현황 / 확인 필요 항목

## 설치

이 저장소를 클론한 위치에서 Claude Code를 실행하면 `.claude/skills/` 아래 스킬이 자동으로 인식된다.
다른 프로젝트에서 쓰려면 스킬 디렉터리를 복사한다.

```bash
cp -r .claude/skills/qa-report /path/to/your-project/.claude/skills/
# 또는 사용자 전역으로
cp -r .claude/skills/qa-report ~/.claude/skills/
```
