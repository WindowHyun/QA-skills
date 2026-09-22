<!--
이 스킬로 실제 생성된 리포트 예시 (3차 반복 결과).
대상: 샘플 Node.js 주문/쿠폰 서비스의 "쿠폰 중복 적용 + 포인트 결제" 변경 (3파일, +59/-32).
의도적으로 심어둔 결함 14건을 전부 발견했고, 심지 않은 문제도 추가로 찾았다.
위험 지점 14건 / 테스트 케이스 25건 / 확정 결함 16건 / 코드 근거 인용 159회.
-->

# QA 리포트: feature/multi-coupon-points (쿠폰 중복 적용 · 포인트 결제)

| 항목 | 내용 |
|---|---|
| 작성일 | 2026-09-22 |
| 분석 대상 | `feature/multi-coupon-points` 브랜치 (`a399e31` feat: 쿠폰 중복 적용 및 포인트 결제 지원) |
| 비교 기준 | `main` @ `6e24aa2` |
| 변경 규모 | 파일 3개, +59/-32 라인 (`src/coupon.js`, `src/order.js`, `src/routes.js`) |
| 분석 제외 | 없음. 변경 파일 3개 전부와 변경 파일이 호출하는 기존 파일(`src/db.js`, `src/inventory.js`)까지 읽고 실행 검증함 |
| 검증 방식 | 저장소 밖 스크래치 스크립트로 `createOrder` / `applyCoupon` / 라우트 핸들러를 목 `req`/`res`로 직접 호출해 실측. 본문의 모든 수치는 추정이 아니라 실행 결과다 |

## 1. 요약

이번 변경은 (a) 쿠폰을 최대 3장까지 중복 적용하고, (b) 주문 시 포인트로 결제 금액을 차감하는 기능을 추가한다.
그러나 **포인트 잔액 검증, 할인 총액 상한, 주문 소유권 검사가 셋 다 없다.** 실행해 본 결과 쿠폰 3장으로 `total=-5000`,
포인트 초과 사용으로 `total=-989999` / `user.points=-998999`가 실제로 만들어지고, 다른 사용자의 주문을 200 OK로 조회할 수 있다.

기능 추가와 무관하게 **조용히 같이 사라진 코드가 두 군데** 있다. `GET /orders/:id`의 소유권 검사(403)와
주문 저장 실패 시 재고를 되돌리는 보상 로직이다. 커밋 메시지에는 둘 다 언급이 없다.
또한 주문 저장과 재고 차감의 **순서가 뒤집혀서**, 재고 부족 시 400 응답을 받았는데도 `status: PAID` 주문이 DB에 남고 포인트도 차감된 채로 끝난다.

**가장 중요한 사실: 기존 테스트(`npm test`)는 위 결함을 전부 안고도 `ok`로 통과한다.**
`tests/coupon.test.js`는 `applyCoupon()` 1장짜리 경로만 검증하며, 이번에 추가된 `applyCoupons()` · `createOrder()`의 포인트 분기 ·
`routes.js`는 자동화 커버리지가 **0**이다. 이번 변경은 CI 초록불로 걸러지지 않으므로 아래 수동 검증이 유일한 안전망이다.

| 우선순위 | 위험 지점 | 테스트 케이스 |
|---|---|---|
| P0 | 5건 | 8건 |
| P1 | 5건 | 11건 |
| P2 | 4건 | 6건 |

**릴리즈 전 필수 확인**: TC-01, TC-02, TC-03, TC-04, TC-05, TC-06, TC-07, TC-08 (P0 8건 전부)

## 2. 변경 내용 (기능 관점)

### 2.1 의도된 기능 변경

- 주문 시 쿠폰을 **최대 3장까지 중복 적용**할 수 있다. 상한은 `MAX_COUPONS = 3` (`src/coupon.js:4`).
  각 쿠폰의 할인액은 **할인 전 원래 주문 금액(subtotal) 기준**으로 각각 계산되어 단순 합산된다 (`src/coupon.js:29-40`).
- 주문 요청에 `usePoints`를 넣으면 그 금액만큼 사용자 포인트가 차감되고 결제 금액에서 빠진다 (`src/order.js:38-42`).
- 주문 API 요청 파라미터가 `couponCode`(단수 문자열) → `couponCodes`(배열)로, 응답 필드가
  `discount`(숫자) → `discounts`(적용 쿠폰 배열) + `pointsUsed`로 바뀌었다 (`src/routes.js:10-11`, `src/routes.js:16-17`, `src/routes.js:35-36`).
- 주문 레코드에 `coupons`, `pointsUsed` 필드가 추가되었다 (`src/order.js:50-51`).

### 2.2 조용히 같이 바뀐 것

커밋 메시지("쿠폰 중복 적용 및 포인트 결제 지원")에 근거가 없는 변경이다. 의도인지 실수인지 코드만으로는 판단할 수 없으므로 8장에 확인 항목으로도 올렸다.

- **`GET /orders/:id`의 주문 소유권 검사가 삭제되었다.** main의 `src/routes.js:26-28`에 있던
  `if (order.userId !== req.user.id) return res.status(403)` 블록이 통째로 사라졌다 (현재 `src/routes.js:27-40`).
  쿠폰·포인트 기능과 아무 관련이 없는 변경이다. → R-1
- **주문 저장 실패 시 재고를 되돌리는 보상 로직이 삭제되었다.** main의 `src/order.js:37-52`에 있던
  `try { saveOrder } catch { releaseStock; throw }` 구조가 사라졌다 (현재 `src/order.js:56-58`).
  `releaseStock`은 여전히 import되고 `module.exports`에까지 추가되었지만(`src/order.js:3`, `src/order.js:63`)
  **저장소 어디에서도 호출되지 않는 죽은 코드**다(`grep -rn releaseStock src tests`로 확인). → R-5
- **주문 저장과 재고 차감의 순서가 뒤집혔다.** main은 `reserveStock()` → `saveOrder()` 순서였는데(main `src/order.js:35`, `:48`),
  현재는 `saveOrder()` → `reserveStock()` 순서다 (`src/order.js:56`, `:58`). → R-5
- **주문자 식별이 `req.user.id` 단독에서 `req.body.userId || req.user.id`로 바뀌었다** (`src/routes.js:8`, main `src/routes.js:7` 대비).
  요청 본문 값이 인증 주체보다 우선한다. → R-2
- **쿠폰 만료 판정이 Date 비교에서 문자열 비교로 바뀌었다.**
  main: `new Date(coupon.expiresAt) < new Date()` (main `src/coupon.js:12-13`) →
  현재: `coupon.expiresAt < new Date().toISOString().slice(0, 10)` (`src/coupon.js:13-14`).
  동작이 실제로 달라진다(만료 당일 쿠폰이 유효해지고, 날짜 형식/타임존에 따라 만료 쿠폰이 통과한다). → R-8
- **`GET /orders/:id` 응답에서 `discount` 필드가 제거되었다** (`src/routes.js:32-39`, main `src/routes.js:29-35` 대비).
  주문 레코드에는 `discount`가 그대로 남아 있는데(`src/order.js:49`) 응답에서만 빠졌다. → R-9

## 3. 회귀 영향 범위

**(1) 변경된 코드를 쓰는 곳** — 이번 변경이 기존 기능을 깨뜨리는 방향

| 변경된 대상 | 호출/사용 지점 | 영향 받는 기능 |
|---|---|---|
| `createOrder()` 시그니처 변경 (`src/order.js:17`) | `src/routes.js:7-12` (유일한 호출자) | 주문 생성 API 전체. 3번째 인자가 문자열→배열, 4번째 인자 신설 |
| `applyCoupon()` 만료 판정 로직 (`src/coupon.js:13-14`) | `src/coupon.js:34` (`applyCoupons` 내부), `tests/coupon.test.js:10-14` | 쿠폰 1장 적용 경로 전체 — 중복 적용을 쓰지 않는 기존 단일 쿠폰 주문도 영향 |
| `coupon.js` export 목록 (`src/coupon.js:42`) | `src/order.js:2`, `tests/coupon.test.js:3` | 기존 `applyCoupon` export는 유지됨 → 기존 테스트는 계속 컴파일/통과 |
| POST /orders 응답 필드 `discount` → `discounts` (`src/routes.js:16`) | 저장소 내 소비자 없음 (외부 클라이언트) | 주문 완료 화면의 할인 표시 — 구버전 클라이언트 |
| GET /orders/:id 응답 필드 (`src/routes.js:35-36`) | 저장소 내 소비자 없음 (외부 클라이언트) | 주문 상세 화면 |
| 주문 레코드 스키마 +`coupons`/`pointsUsed` (`src/order.js:50-51`) | `src/routes.js:16-17`, `:35-36` | main 시절 생성된 기존 주문 조회 시 해당 키가 응답에서 누락됨 |

**(2) 변경된 코드가 쓰는 곳** — 기존 코드가 새 사용 방식에 못 버티는 방향

| 호출되는 기존 코드 | 이번 변경으로 달라지는 점 | 그래서 새로 생기는 위험 |
|---|---|---|
| `reserveStock()` (`src/inventory.js:4`) | 호출 시점이 `saveOrder()` **이후**로 이동 (`src/order.js:58`). 실패해도 되돌릴 코드가 없음 | 재고 부족 시 PAID 주문 + 포인트 차감만 남는 부분 완료 상태 → R-5 |
| `releaseStock()` (`src/inventory.js:17`) | 호출이 완전히 사라짐. import와 re-export만 남음 (`src/order.js:3`, `:63`) | 어떤 실패 경로에서도 재고 복구가 일어나지 않음 → R-5 |
| `db.saveUser()` (`src/db.js:11`) | 신규 호출. 주문 흐름에서 **처음으로** 사용자 레코드를 쓴다 (`src/order.js:40`) | 읽기-수정-쓰기 사이에 락이 없어 동시 주문 시 포인트 lost update → R-13 |
| `db.getUser()` (`src/db.js:7`) | 반환 객체를 읽기만 하던 것에서 **직접 변이**(`user.points -= ...`)하는 것으로 변경 (`src/order.js:39`) | `db.js`가 Map에 담긴 객체 참조를 그대로 반환하므로(`src/db.js:8`) `saveUser` 실패 여부와 무관하게 메모리 상태가 먼저 바뀜 → R-13 |
| `db.saveOrder()` (`src/db.js:32`) | 호출 순서가 재고 차감 **앞**으로 이동 (`src/order.js:56`) | 실패 시 롤백 대상이 생겼는데 롤백이 없음 → R-5 |
| `db.getCoupon()` (`src/db.js:16`) | 1주문당 1회 → 최대 3회 반복 호출 (`src/coupon.js:34`) | 루프 내 순차 await. 쿠폰 저장소가 원격 DB로 바뀌면 지연 3배 → 9장 개선 제안 |
| `db.getProduct()` (`src/db.js:20`) | 변화 없음 (항목 수만큼 반복, `src/order.js:10`) | 기존 N+1 유지. 이번 변경으로 악화되지 않음 |
| `db.getStock()` / `db.setStock()` (`src/db.js:24`, `:28`) | 호출 횟수·순서 자체는 동일하나 호출 위치가 저장 이후로 이동 | 기존 check-then-set 경쟁 상태가 이제 "주문은 남고 재고만 어긋나는" 형태로 드러남 → R-13 |
| `calcSubtotal()` (`src/order.js:7`) | 변화 없음 | 변화 없음 |

## 4. 위험 지점

### R-1. `GET /orders/:id`에서 주문 소유권 검사가 사라져 아무나 남의 주문을 조회할 수 있다 [P0]

- **근거**: `src/routes.js:27-40` (main `src/routes.js:26-28`의 403 블록 삭제)
- **무슨 일이 일어나는가**: 주문 ID만 알면 `req.user.id`와 무관하게 200 OK로 주문 상세가 반환된다.
  주문 ID는 `ORD-${seq++}` 형태의 순차 증가 값이므로(`src/order.js:45`) 열거가 자명하다 — `ORD-1`부터 훑으면 전체 주문을 긁을 수 있다.
- **영향**: 타인의 결제 금액·사용 포인트·적용 쿠폰이 노출된다(IDOR). 실측: 사용자 u1 세션으로 u2 소유 주문 조회 시 `status=200`, 바디에 `total`/`pointsUsed` 전부 포함.
- **관련 테스트 케이스**: TC-01

### R-2. 주문자 ID를 요청 본문에서 받아, 타인 명의 주문과 타인 포인트 차감이 가능하다 [P0]

- **근거**: `src/routes.js:8` (`req.body.userId || req.user.id`)
- **무슨 일이 일어나는가**: `req.body.userId`가 인증 주체보다 우선한다. `createOrder`는 이 값으로 `db.getUser()`를 조회해(`src/order.js:18`)
  그 사용자의 포인트를 차감한다(`src/order.js:39`). 인증 주체와 일치하는지 확인하는 코드가 어디에도 없다.
- **영향**: 실측 — u1 세션에서 `{userId:'u2', usePoints:5000}` 전송 시 201 Created, **u2의 포인트가 5000 → 0**으로 차감되고
  주문 소유자는 u2로 기록된다. R-1과 결합하면 "남의 포인트를 태워 주문을 만들고 그 주문을 조회"까지 한 번에 가능하다.
  `req.user`가 아예 없는 요청(인증 미들웨어 미적용 경로)에서도 `req.body.userId`만으로 201이 떨어진다.
- **관련 테스트 케이스**: TC-02, TC-03

### R-3. 포인트 사용량을 보유 잔액과 대조하지 않는다 [P0]

- **근거**: `src/order.js:38-42`
- **무슨 일이 일어나는가**: `usePoints > 0`인지만 보고 곧바로 `user.points -= usePoints`를 실행한다.
  보유 잔액 확인, 상한 절삭, 예외 발생이 전부 없다. 차감된 사용자는 그대로 `db.saveUser()`로 영속화된다(`src/order.js:40`).
- **영향**: 실측 — 보유 1,000P 계정에서 `usePoints=999999` 요청 시 201 Created, **`user.points = -998999`**, **`total = -989999`**.
  결제 금액이 음수가 되어 정산이 깨지고, 포인트 잔액도 음수로 영구 저장된다.
- **관련 테스트 케이스**: TC-04, TC-05

### R-4. 다중 쿠폰 할인 합계에 상한이 없어 결제 금액이 음수가 된다 [P0]

- **근거**: `src/coupon.js:29-40`, `src/order.js:36`
- **무슨 일이 일어나는가**: `applyCoupons()`는 각 쿠폰을 **할인 전 subtotal 기준**으로 계산해(`src/coupon.js:34`) 단순 합산한다(`src/coupon.js:36`).
  중복 코드 제거도, `totalDiscount <= subtotal` 검사도 없다. `createOrder`도 `subtotal - discount`를 그대로 쓴다(`src/order.js:36`).
- **영향**: 실측 — 10,000원 주문에 50% 할인 쿠폰(RATE50) 3장 적용 시 `discount=15000`, **`total=-5000`**.
  9,000원 정액 쿠폰 2장이면 `discount=18000`, **`total=-8000`**. 음수 결제 금액이 PAID 상태로 저장된다.
- **관련 테스트 케이스**: TC-06, TC-07

### R-5. 주문 저장 후 재고를 차감하고 실패 시 되돌리지 않아, 유령 PAID 주문이 남는다 [P0]

- **근거**: `src/order.js:56-58` (main `src/order.js:35-52`의 순서 및 보상 로직 대비)
- **무슨 일이 일어나는가**: 순서가 `saveOrder()` → `reserveStock()`로 뒤집혔고(`src/order.js:56`, `:58`),
  main에 있던 `try/catch` + `releaseStock()` 보상이 삭제되었다. `reserveStock()`이 `OUT_OF_STOCK`을 던지면(`src/inventory.js:8`)
  예외는 라우트의 catch로 올라가 400이 되지만(`src/routes.js:21-23`), 이미 저장된 주문과 이미 차감된 포인트는 그대로 남는다.
- **영향**: 실측 — 재고 1개인 상품을 10개 주문(+포인트 300 사용) 시 응답은 `400 {"error":"OUT_OF_STOCK:p1"}`인데
  DB에는 **`status: PAID`, `total: 9700` 주문이 그대로 남고**, 사용자 포인트는 1000 → **700**으로 차감된 채이며, 재고는 차감되지 않는다.
  그 유령 주문은 `GET /orders/:id`로 200 OK 조회까지 된다. 사용자는 "주문 실패" 화면을 보지만 포인트는 사라지고 주문 목록에는 결제 완료 주문이 생긴다.
- **관련 테스트 케이스**: TC-08

### R-6. 동일 쿠폰 코드를 중복 사용할 수 있다 [P1]

- **근거**: `src/coupon.js:33-37`
- **무슨 일이 일어나는가**: 루프가 코드 배열을 그대로 순회할 뿐 중복 제거나 사용 이력 확인이 없다.
  `db.getCoupon()`도 사용 여부를 기록하지 않는다(`src/db.js:16-18`).
- **영향**: 실측 — `['RATE50','RATE50','RATE50']` 전송 시 3장 모두 적용되어 `applied` 배열에 같은 코드가 3번 들어간다.
  1인 1매 쿠폰이 3배로 쓰인다. R-4와 결합해 음수 결제로 직결된다.
- **관련 테스트 케이스**: TC-09

### R-7. 4장 이상 쿠폰을 보내면 초과분이 조용히 무시된다 [P1]

- **근거**: `src/coupon.js:33` (`codes.slice(0, MAX_COUPONS)`)
- **무슨 일이 일어나는가**: 상한 초과 시 예외를 던지지 않고 앞 3장만 잘라 쓴다. 경고·에러 코드·로그가 없다.
- **영향**: 실측 — `['RATE10','RATE10','RATE10','FLAT9000']` 전송 시 FLAT9000이 말없이 버려지고 `discount=3000`으로 처리된다.
  사용자는 4장을 적용했다고 믿지만 실제 할인은 3장분이다. 응답의 `discounts` 배열을 봐야만 알 수 있다.
- **관련 테스트 케이스**: TC-10

### R-8. 쿠폰 만료 판정이 문자열 비교로 바뀌어 형식·타임존에 따라 만료 쿠폰이 통과한다 [P1]

- **근거**: `src/coupon.js:13-14` (main `src/coupon.js:12-13` 대비)
- **무슨 일이 일어나는가**: `coupon.expiresAt < '2026-09-22'` 형태의 **문자열 사전식 비교**다. 세 가지 경로로 깨진다.
  (a) `expiresAt`이 `YYYY-MM-DD`가 아닌 형식(`2026/09/21`, `2026-9-21`)이면 `/`(0x2F)와 미패딩 숫자가 `-`(0x2D)보다 커서 **만료일이 지났는데 유효**로 판정된다.
  (b) `expiresAt`이 `null`이면 숫자 비교로 강등되어 항상 false → **영구 유효**. main에서는 `new Date(null)`이 epoch라 만료 처리되던 값이다.
  (c) 기준 날짜가 `toISOString()` 기반의 **UTC 날짜**다. KST 00:00~09:00 사이에는 UTC 날짜가 전날이라 전날 만료된 쿠폰이 계속 통과한다.
  추가로 만료 당일 쿠폰의 판정이 main(만료)에서 현재(유효)로 뒤집힌다 — 의도된 수정일 수 있으나 커밋 메시지에 근거가 없다.
- **영향**: 실측 — `expiresAt='2026/09/21'` → 유효(할인 1000원 적용), `expiresAt=null` → 유효,
  시계를 KST 2026-09-23 08:00(UTC 2026-09-22 23:00)로 고정하면 `expiresAt='2026-09-22'` 쿠폰이 유효.
  main 동일 입력에서는 `2026/09/21`은 만료, `null`은 만료로 처리됐다.
- **관련 테스트 케이스**: TC-11, TC-12, TC-13, TC-14

### R-9. API 응답 필드 변경으로 구버전 클라이언트와 기존 주문 데이터가 깨진다 [P1]

- **근거**: `src/routes.js:16-17`, `src/routes.js:35-36` (main `src/routes.js:11`, `:32` 대비)
- **무슨 일이 일어나는가**: `discount`(숫자)가 두 엔드포인트 모두에서 제거되고 `discounts`(배열) + `pointsUsed`로 대체됐다.
  구버전 프런트엔드가 `order.discount`를 읽으면 `undefined`다. 반대로 main 시절 생성된 주문 레코드에는
  `coupons`/`pointsUsed` 필드가 없어서 JSON 직렬화 시 해당 키가 **응답에서 통째로 사라진다**.
- **영향**: 실측 — main 스키마 주문(`{discount:1000, total:9000}`)을 `GET /orders/:id`로 조회하면
  응답이 `{"id":"ORD-OLD","subtotal":10000,"total":9000,"status":"PAID"}` — 할인 정보가 어느 필드로도 나오지 않는다.
  배포 직후 기존 주문의 주문 상세 화면에서 할인 금액이 사라진다.
- **관련 테스트 케이스**: TC-15, TC-16

### R-10. 구버전 클라이언트가 보내는 `couponCode`(단수)가 무시되어 정가로 결제된다 [P1]

- **근거**: `src/routes.js:10` (`req.body.couponCodes || []`)
- **무슨 일이 일어나는가**: 파라미터 이름이 `couponCode` → `couponCodes`로 바뀌었는데 구 파라미터 폴백이 없다.
  구버전 앱이 보낸 `couponCode`는 읽히지 않고 빈 배열이 되어, 쿠폰 없는 주문으로 **성공(201)** 처리된다.
- **영향**: 실측 — `{items, couponCode:'RATE50'}` 전송 시 `201`, `discounts: []`, `total: 10000`(정가).
  에러가 아니라 성공이라 사용자도 모니터링도 눈치채지 못한 채 과금된다. 앱 강제 업데이트 전까지 CS 유입이 예상된다.
- **관련 테스트 케이스**: TC-17

### R-11. `usePoints`에 음수를 넣으면 차감 없이 `pointsUsed: -N`이 주문에 기록된다 [P2]

- **근거**: `src/order.js:38` (`if (usePoints > 0)`), `src/order.js:51`
- **무슨 일이 일어나는가**: 음수는 `> 0` 조건에 걸리지 않아 차감 블록을 건너뛰지만,
  `pointsUsed: usePoints`는 조건 밖에서 무조건 기록된다(`src/order.js:51`).
- **영향**: 실측 — `usePoints=-5000` 요청 시 `total=10000`(정상), 포인트 차감 없음(1000 유지), 그러나 주문 레코드와 API 응답에 `pointsUsed: -5000`이 남는다.
  포인트 적립으로 이어지진 않으나 주문 데이터와 정산 집계가 어긋난다. 음수 요청을 거부하지 않는다는 점 자체가 R-3와 함께 검증 부재의 신호다.
- **관련 테스트 케이스**: TC-18

### R-12. `points` 필드가 없는 사용자의 포인트가 `NaN`으로 영구 저장된다 [P2]

- **근거**: `src/order.js:39-40`
- **무슨 일이 일어나는가**: `user.points`가 `undefined`면 `undefined - 500`이 `NaN`이 되고, 검증 없이 `db.saveUser()`로 저장된다.
  `total -= usePoints`는 정상 동작하므로 할인은 그대로 적용된다.
- **영향**: 실측 — `points` 필드가 없는 계정으로 `usePoints=500` 주문 시 `total=9500`(할인 적용됨),
  해당 사용자 레코드의 `points`가 **`NaN`**이 되어 복구 전까지 이후 모든 포인트 연산이 오염된다.
  신규 가입자나 마이그레이션 누락 계정이 여기 해당한다.
- **관련 테스트 케이스**: TC-19

### R-13. 동시 주문 시 재고 초과 판매와 포인트 lost update가 발생한다 [P2]

- **근거**: `src/inventory.js:4-15`(검사 루프와 차감 루프 분리), `src/order.js:39-40`(락 없는 읽기-수정-쓰기)
- **무슨 일이 일어나는가**: `reserveStock()`은 전 항목을 검사한 뒤 별도 루프에서 차감하므로 두 요청이 같은 재고를 동시에 통과한다.
  포인트도 잔액 검사 자체가 없어(R-3) 동시성과 무관하게 음수가 되지만, 동시 요청에서는 차감 결과까지 서로 덮어쓸 수 있다.
  경쟁 상태 자체는 main에도 있었으나, 재고 차감이 주문 저장 **뒤로** 밀리면서(R-5) 실패해도 주문이 남는 형태로 결과가 악화됐다.
- **영향**: 실측 — 재고 5개 상품에 5개씩 2건 동시 주문 시 둘 다 성공(주문 2건 생성), 최종 재고 `0` → **5개 초과 판매**.
  포인트 5,000P 계정에서 5,000P씩 2건 동시 주문 시 둘 다 성공, 잔액 **-5000**.
- **관련 테스트 케이스**: TC-20

### R-14. `couponCodes`에 배열이 아닌 문자열이 오면 문자 단위로 순회한다 [P2]

- **근거**: `src/coupon.js:33` (`codes.slice(0, 3)`), `src/routes.js:10`
- **무슨 일이 일어나는가**: 타입 검사가 없다. 문자열도 `.length`와 `.slice()`를 가지므로 `'RATE50'`은 `'RAT'`로 잘리고
  `for...of`가 `'R'`, `'A'`, `'T'` 세 글자를 각각 쿠폰 코드로 조회한다.
- **영향**: 실측 — `couponCodes: 'RATE50'` 전송 시 `400 {"error":"COUPON_NOT_FOUND"}`.
  돈이 새지는 않으나 클라이언트 구현 실수를 "쿠폰이 없다"는 엉뚱한 메시지로 되돌려주어 CS·디버깅 비용이 든다.
- **관련 테스트 케이스**: TC-21

## 5. 발견된 결함

코드를 읽고 **실제로 실행해 확정한** 문제다. 각 항목의 메커니즘은 4장의 R 번호를 참조한다.

| ID | 내용 | 위치 | 심각도 |
|---|---|---|---|
| D-1 | 주문 소유권 검사 삭제 — 타인 주문이 200 OK로 조회됨. 주문 ID가 순차 증가라 열거 가능 (R-1) | `src/routes.js:27-40` | P0 |
| D-2 | `req.body.userId`가 인증 주체를 덮어써 타인 명의 주문·타인 포인트 차감 가능 (R-2) | `src/routes.js:8` | P0 |
| D-3 | 포인트 잔액 미검증 — 실측 `user.points=-998999`, `total=-989999` (R-3) | `src/order.js:38-42` | P0 |
| D-4 | 다중 쿠폰 할인 합계 상한 없음 — 실측 `total=-5000` (RATE50×3), `total=-8000` (FLAT9000×2) (R-4) | `src/coupon.js:36`, `src/order.js:36` | P0 |
| D-5 | 저장 후 재고 차감 + 보상 로직 삭제 — 400 응답인데 PAID 주문 잔존, 포인트 차감 유지 (R-5) | `src/order.js:56-58` | P0 |
| D-6 | `releaseStock`이 import·re-export만 되고 호출처가 없는 죽은 코드 (R-5) | `src/order.js:3`, `src/order.js:63` | P0 |
| D-7 | 동일 쿠폰 코드 중복 적용 허용 (R-6) | `src/coupon.js:33-37` | P1 |
| D-8 | `expiresAt`이 `null`이거나 `YYYY-MM-DD` 형식이 아니면 만료 쿠폰이 유효 판정 — main 대비 회귀 (R-8) | `src/coupon.js:13-14` | P1 |
| D-9 | 만료 기준 날짜가 UTC — KST 00:00~09:00에 전날 만료 쿠폰 통과 (R-8) | `src/coupon.js:13` | P1 |
| D-10 | main 시절 주문 조회 시 할인 정보가 응답에서 완전히 사라짐 (`discount` 제거 + `coupons` 부재) (R-9) | `src/routes.js:35-36` | P1 |
| D-11 | 구 파라미터 `couponCode` 폴백 부재 — 구버전 앱이 정가로 결제 성공(201) (R-10) | `src/routes.js:10` | P1 |
| D-12 | 쿠폰 4장 이상 시 초과분 무음 절삭 (R-7) | `src/coupon.js:33` | P1 |
| D-13 | 음수 `usePoints`가 `pointsUsed: -N`으로 주문에 기록됨 (R-11) | `src/order.js:38`, `src/order.js:51` | P2 |
| D-14 | `points` 미보유 사용자의 잔액이 `NaN`으로 저장됨 (R-12) | `src/order.js:39-40` | P2 |
| D-15 | 동시 주문 시 재고 초과 판매(재고 5, 판매 10) (R-13) | `src/inventory.js:4-15` | P2 |
| D-16 | `couponCodes`가 문자열이면 문자 단위 순회 후 `COUPON_NOT_FOUND` (R-14) | `src/coupon.js:33` | P2 |

## 6. 테스트 케이스

> ### 공통 사전조건(SETUP) / 실행 방법
>
> **중요 — 이 저장소에는 HTTP 서버 부트스트랩이 없다.** `src/routes.js`는 핸들러 함수만 export하고(`src/routes.js:42`),
> `app.listen`도 start 스크립트도 존재하지 않는다(`package.json`). 저장소도 `src/db.js`의 인메모리 Map이다(`src/db.js:2-5`).
> 따라서 **curl이나 UI로는 검증할 수 없고**, 아래 하네스로 핸들러를 직접 호출한다. 저장소 코드는 수정하지 않는다.
>
> 1. 저장소 **밖**에 `qa-harness.js`를 만든다(예: `~/qa/qa-harness.js`). `REPO`는 체크아웃 경로로 바꾼다.
>
> ```js
> const REPO = '/path/to/repo';          // feature/multi-coupon-points 체크아웃 경로
> const db = require(REPO + '/src/db');
> const { postOrder, getOrderDetail } = require(REPO + '/src/routes');
> const { createOrder } = require(REPO + '/src/order');
> const { applyCoupon } = require(REPO + '/src/coupon');
>
> // 목 res: status/json 을 기록만 한다
> function mkRes() {
>   const r = { code: 200, body: null };
>   r.status = (c) => { r.code = c; return r; };
>   r.json = (b) => { r.body = b; return r; };
>   return r;
> }
>
> // SETUP: 모든 TC 시작 전에 호출한다
> function setup() {
>   db._raw.users.clear(); db._raw.orders.clear();
>   db._raw.coupons.clear(); db._raw.stock.clear();
>   db._raw.users.set('u1', { id: 'u1', points: 1000 });   // 구매자
>   db._raw.users.set('u2', { id: 'u2', points: 5000 });   // 피해자 계정
>   db._raw.stock.set('p1', 100);                          // 상품 p1: 단가 1000원 고정(src/db.js:21)
>   db._raw.coupons.set('RATE10',   { code:'RATE10',   type:'RATE', value:0.1,  expiresAt:'2099-12-31' });
>   db._raw.coupons.set('RATE50',   { code:'RATE50',   type:'RATE', value:0.5,  expiresAt:'2099-12-31' });
>   db._raw.coupons.set('FLAT1000', { code:'FLAT1000', type:'FLAT', value:1000, expiresAt:'2099-12-31' });
>   db._raw.coupons.set('FLAT9000', { code:'FLAT9000', type:'FLAT', value:9000, expiresAt:'2099-12-31' });
> }
> module.exports = { db, postOrder, getOrderDetail, createOrder, applyCoupon, mkRes, setup };
> ```
>
> 2. 각 TC는 `setup()` 호출로 시작한다. **TC 간 상태가 남으므로 반드시 매번 호출한다**(주문 ID `seq`는 프로세스 전역이라 이어진다, `src/order.js:5`).
> 3. **표준 주문 항목**: `const items = [{ productId: 'p1', quantity: 10 }]` → subtotal **10,000원**.
> 4. **표준 요청**: `await postOrder({ user: {id:'u1'}, body: { items, couponCodes: [...], usePoints: N } }, res)` 후 `res.code` / `res.body` 확인.
> 5. DB 실제 상태는 `db._raw.users.get('u1').points`, `db._raw.orders.size`, `db._raw.stock.get('p1')`로 직접 확인한다.
> 6. `기대 / 현재` 표기가 있는 행은 **이미 확정된 결함**이다. 재현되면 신규 버그로 등록하지 말고 해당 D 번호로 보고한다.

| TC | P | 검증 항목 | 사전조건 | 절차 | 기대 결과 | 근거 | 자동화 |
|---|---|---|---|---|---|---|---|
| TC-01 | P0 | 타인 주문 조회 차단 (IDOR) | SETUP | 1) `postOrder({user:{id:'u2'}, body:{items}}, res1)`로 u2 주문 생성 2) 응답의 `id`를 기록 3) `getOrderDetail({user:{id:'u1'}, params:{id:<그 id>}}, res2)` 호출 4) `res2.code` 확인 | `403` + `{error:'FORBIDDEN'}` — **기대: 403 / 현재: 200 + 주문 전체 바디 반환 — 실패 예상 (D-1)** | `src/routes.js:27-40` | 없음 |
| TC-02 | P0 | 요청 본문 `userId`로 타인 명의 주문·타인 포인트 차감 | SETUP (u2 보유 5000P) | 1) `postOrder({user:{id:'u1'}, body:{userId:'u2', items, usePoints:5000}}, res)` 2) `res.code` 확인 3) `db._raw.users.get('u2').points` 확인 4) `[...db._raw.orders.values()][0].userId` 확인 | 401 또는 403, u2 포인트 5000 유지 — **기대: 거부 / 현재: 201, u2.points=0, 주문 소유자='u2' — 실패 예상 (D-2)** | `src/routes.js:8`, `src/order.js:39` | 없음 |
| TC-03 | P0 | 인증 주체 없이 `userId`만으로 주문 | SETUP | 1) `postOrder({ body:{userId:'u2', items} }, res)` — `req.user` 자체를 넣지 않는다 2) `res.code` 확인 | 401 (인증 없음) — **기대: 401 / 현재: 201 Created — 실패 예상 (D-2)** | `src/routes.js:8` | 없음 |
| TC-04 | P0 | 보유 잔액 초과 포인트 사용 | SETUP (u1 보유 1,000P) | 1) `postOrder({user:{id:'u1'}, body:{items, usePoints:999999}}, res)` 2) `res.code`/`res.body.total` 확인 3) `db._raw.users.get('u1').points` 확인 | 400 + 잔액 부족 에러, 포인트 1000 유지 — **기대: 400 / 현재: 201, total=-989999, u1.points=-998999 — 실패 예상 (D-3)** | `src/order.js:38-42` | 없음 |
| TC-05 | P0 | 포인트가 결제 금액을 초과 (경계: 잔액은 충분) | SETUP 후 `db._raw.users.get('u1').points = 20000` | 1) `postOrder({user:{id:'u1'}, body:{items, usePoints:20000}}, res)` (주문액 10,000원) 2) `res.body.total` 확인 | total은 0 미만이 될 수 없고 초과분 10,000P는 차감되지 않아야 함 — **기대: total=0 & 잔액 10000 / 현재: total=-10000, u1.points=0 — 실패 예상 (D-3)** | `src/order.js:41` | 없음 |
| TC-06 | P0 | 정률 쿠폰 중복으로 할인이 주문액 초과 | SETUP | 1) `postOrder({user:{id:'u1'}, body:{items, couponCodes:['RATE50','RATE50','RATE50']}}, res)` 2) `res.body.total` 확인 | total 0 이상 — **기대: total>=0 / 현재: discount=15000, total=-5000 — 실패 예상 (D-4)** | `src/coupon.js:34-36`, `src/order.js:36` | 없음 |
| TC-07 | P0 | 정액 쿠폰 중복으로 할인이 주문액 초과 | SETUP | 1) `postOrder({user:{id:'u1'}, body:{items, couponCodes:['FLAT9000','FLAT9000']}}, res)` 2) `res.body.total` 확인 | total 0 이상 — **기대: total>=0 / 현재: discount=18000, total=-8000 — 실패 예상 (D-4)** | `src/coupon.js:36` | 없음 |
| TC-08 | P0 | 재고 부족 시 주문·포인트 롤백 | SETUP 후 `db._raw.stock.set('p1', 1)` | 1) `postOrder({user:{id:'u1'}, body:{items, usePoints:300}}, res)` (10개 주문) 2) `res.code` 확인 3) `db._raw.orders.size` 확인 4) `db._raw.users.get('u1').points` 확인 5) 남은 주문 ID로 `getOrderDetail` 호출 | 400 + 주문 0건 + 포인트 1000 유지 — **기대: orders.size=0, points=1000 / 현재: 400이지만 PAID 주문 1건(total=9700) 잔존, points=700, 그 주문이 GET 200으로 조회됨 — 실패 예상 (D-5)** | `src/order.js:56-58`, `src/inventory.js:8` | 없음 |
| TC-09 | P1 | 동일 쿠폰 코드 중복 사용 차단 | SETUP | 1) `postOrder({user:{id:'u1'}, body:{items, couponCodes:['RATE10','RATE10']}}, res)` 2) `res.body.discounts` 배열 확인 | 중복 코드 거부 또는 1장만 적용 — **기대: 1장 / 현재: 2장 모두 적용(각 1000원, discount=2000) — 실패 예상 (D-7)** | `src/coupon.js:33-37` | 없음 |
| TC-10 | P1 | 쿠폰 상한(3장) 초과 시 안내 | SETUP | 1) `postOrder({user:{id:'u1'}, body:{items, couponCodes:['RATE10','FLAT1000','RATE10','FLAT9000']}}, res)` 2) `res.code`와 `res.body.discounts.length` 확인 | 400 + 상한 초과 에러 (또는 명시적 안내) — **기대: 에러 / 현재: 201, 앞 3장만 조용히 적용, 4번째 무시 — 실패 예상 (D-12)** | `src/coupon.js:33` | 없음 |
| TC-11 | P1 | 만료 당일 쿠폰 판정 (main 대비 동작 반전) | SETUP 후 `db._raw.coupons.set('TODAY',{code:'TODAY',type:'FLAT',value:1000,expiresAt:<오늘 UTC 날짜 YYYY-MM-DD>})` | 1) `applyCoupon('TODAY', 10000)` 호출 2) 반환값/예외 확인 | 기획 정책에 따름 — **main: COUPON_EXPIRED / 현재: 1000원 할인(유효)**. 8장 확인 항목 ①의 답에 따라 판정 | `src/coupon.js:13-14` | 없음 |
| TC-12 | P1 | `expiresAt`이 `null`인 쿠폰 | SETUP 후 `db._raw.coupons.set('NULLEXP',{code:'NULLEXP',type:'FLAT',value:1000,expiresAt:null})` | 1) `applyCoupon('NULLEXP', 10000)` 호출 | `COUPON_EXPIRED` 또는 데이터 오류 — **기대: 거부 / 현재: 1000원 할인 적용(main에서는 COUPON_EXPIRED) — 실패 예상 (D-8)** | `src/coupon.js:14` | 없음 |
| TC-13 | P1 | `expiresAt` 형식이 `YYYY-MM-DD`가 아닌 만료 쿠폰 | SETUP 후 `expiresAt:'2026/09/21'`(어제, 슬래시)과 `expiresAt:'2026-9-21'`(미패딩) 쿠폰 각각 등록 | 1) 각 코드로 `applyCoupon(code, 10000)` 호출 2) 예외 여부 확인 | 두 건 모두 `COUPON_EXPIRED` — **기대: 거부 / 현재: 둘 다 1000원 할인 적용 — 실패 예상 (D-8)** | `src/coupon.js:14` | 없음 |
| TC-14 | P1 | 만료 기준일의 타임존 (KST 00:00~09:00) | 하네스 상단에서 `Date`를 UTC `2026-09-22T23:00:00Z`(KST 9/23 08:00)로 고정 후 `expiresAt:'2026-09-22'` 쿠폰 등록 | 1) `applyCoupon(code, 10000)` 호출 | KST 기준 전날 만료이므로 `COUPON_EXPIRED` — **기대: 거부 / 현재: 1000원 할인 적용 — 실패 예상 (D-9)** | `src/coupon.js:13` | 없음 |
| TC-15 | P1 | [회귀] 주문 생성 응답 필드 하위 호환 | SETUP | 1) `postOrder({user:{id:'u1'}, body:{items, couponCodes:['FLAT1000']}}, res)` 2) `res.body`의 키 목록 확인 | 구버전 클라이언트용 `discount` 숫자 필드 유지 여부를 기획과 대조 — **현재: `discount` 없음, `discounts`(배열)+`pointsUsed`만 존재 (D-10)** | `src/routes.js:13-20` | 없음 |
| TC-16 | P1 | [회귀] main 스키마로 저장된 기존 주문 조회 | SETUP 후 `db._raw.orders.set('ORD-OLD',{id:'ORD-OLD',userId:'u1',items,subtotal:10000,discount:1000,total:9000,status:'PAID'})` | 1) `getOrderDetail({user:{id:'u1'}, params:{id:'ORD-OLD'}}, res)` 2) `res.body` 확인 | 할인 금액 1,000원이 어떤 형태로든 노출 — **기대: 할인 정보 노출 / 현재: `{"id":"ORD-OLD","subtotal":10000,"total":9000,"status":"PAID"}` — 할인 정보 전부 소실, 실패 예상 (D-10)** | `src/routes.js:32-39`, `src/order.js:49-51` | 없음 |
| TC-17 | P1 | [회귀] 구버전 파라미터 `couponCode`(단수) 주문 | SETUP | 1) `postOrder({user:{id:'u1'}, body:{items, couponCode:'FLAT1000'}}, res)` (복수형 아님) 2) `res.code`/`res.body.total` 확인 | 쿠폰 적용(total 9000) 또는 명시적 400 — **기대: 둘 중 하나 / 현재: 201 + discounts=[] + total=10000 (정가 결제, 무음 실패) — 실패 예상 (D-11)** | `src/routes.js:10` | 없음 |
| TC-18 | P2 | 음수 `usePoints` | SETUP | 1) `postOrder({user:{id:'u1'}, body:{items, usePoints:-5000}}, res)` 2) `res.body.pointsUsed`/`total` 확인 3) `db._raw.users.get('u1').points` 확인 | 400 거부 — **기대: 400 / 현재: 201, total=10000(정상), 포인트 차감 없음(1000 유지), 그러나 pointsUsed=-5000이 주문·응답에 기록 — 실패 예상 (D-13)** | `src/order.js:38`, `src/order.js:51` | 없음 |
| TC-19 | P2 | `points` 필드가 없는 사용자의 포인트 결제 | SETUP 후 `db._raw.users.set('u3',{id:'u3'})` (points 키 없음) | 1) `postOrder({user:{id:'u3'}, body:{items, usePoints:500}}, res)` 2) `db._raw.users.get('u3').points` 확인 | 400 잔액 부족 — **기대: 400 / 현재: 201, total=9500, u3.points=NaN 저장 — 실패 예상 (D-14)** | `src/order.js:39-40` | 없음 |
| TC-20 | P2 | [회귀] 동시 주문 시 재고 초과 판매 | SETUP 후 `db._raw.stock.set('p1', 5)`, 항목을 `quantity:5`로 | 1) `await Promise.all([createOrder('u1',items5,[],0), createOrder('u1',items5,[],0)])` 2) `db._raw.orders.size`, `db._raw.stock.get('p1')` 확인 | 1건 성공 + 1건 `OUT_OF_STOCK`, 재고 0 — **기대: 1건 / 현재: 2건 모두 성공(총 10개 판매), 재고 0 — 실패 예상 (D-15)** | `src/inventory.js:4-15` | 없음 |
| TC-21 | P2 | `couponCodes`에 배열 대신 문자열 전달 | SETUP | 1) `postOrder({user:{id:'u1'}, body:{items, couponCodes:'FLAT1000'}}, res)` 2) `res.body.error` 확인 | 타입 오류를 알리는 400 (예: `INVALID_COUPON_CODES`) — **기대: 타입 에러 / 현재: 400 `COUPON_NOT_FOUND` (문자 'F','L','A' 를 코드로 조회) — 메시지 부정확 (D-16)** | `src/coupon.js:33` | 없음 |
| TC-22 | P1 | [회귀] 단일 정률 쿠폰 주문 금액 불변 | SETUP | 1) `postOrder({user:{id:'u1'}, body:{items, couponCodes:['RATE10']}}, res)` 2) `res.body` 및 `db._raw.stock.get('p1')` 확인 | `subtotal=10000`, 할인 1000, `total=9000`, `status='PAID'`, 재고 100→90 (main과 동일) — **현재: 일치 확인됨** | `src/coupon.js:22-23`, `src/order.js:36` | 부분 (`tests/coupon.test.js:10` — `applyCoupon` 단위만, 주문 흐름 미포함) |
| TC-23 | P1 | [회귀] 단일 정액 쿠폰 + 쿠폰 없는 주문 | SETUP | 1) `couponCodes:['FLAT1000']`로 주문 → total 확인 2) SETUP 재실행 후 `couponCodes` 생략하고 주문 → total·재고 확인 | 1) `total=9000` 2) `total=10000`, `status='PAID'`, 재고 100→90 (main과 동일) — **현재: 일치 확인됨** | `src/coupon.js:25`, `src/order.js:30-36` | 부분 (`tests/coupon.test.js:11`) |
| TC-24 | P2 | [회귀] 최소 주문 금액 미만 시 쿠폰 거부 유지 | SETUP, 항목을 `quantity:4` (4,000원)로 | 1) `postOrder({user:{id:'u1'}, body:{items4, couponCodes:['RATE10']}}, res)` | `400 {"error":"COUPON_MIN_AMOUNT"}` (`MIN_ORDER_AMOUNT=5000`) — **현재: 일치 확인됨** | `src/coupon.js:18-20` | 있음 (`tests/coupon.test.js:14`) |
| TC-25 | P2 | [회귀] 기존 에러 경로 4종 유지 | SETUP | 1) 없는 사용자 `userId:'nobody'` 2) `items: []` 3) `couponCodes:['NOPE']` 4) `getOrderDetail`에 없는 주문 ID | 순서대로 `400 USER_NOT_FOUND` / `400 EMPTY_ITEMS` / `400 COUPON_NOT_FOUND` / `404 NOT_FOUND` — **현재: 4종 모두 일치 확인됨** | `src/order.js:19-24`, `src/coupon.js:9-11`, `src/routes.js:29-31` | 없음 |

**총 25건** — P0 8건(TC-01~TC-08) / P1 11건(TC-09~TC-17, TC-22, TC-23) / P2 6건(TC-18~TC-21, TC-24, TC-25).
이 중 `[회귀]` 표시 케이스는 TC-15, TC-16, TC-17, TC-20, TC-22, TC-23, TC-24, TC-25의 8건이다.

## 7. 자동화 커버리지

`npm test`(`node tests/coupon.test.js`)를 실제로 실행했다. 결과는 **`ok` (exit 0)** — 위 P0 결함 5건을 전부 안은 채 통과한다.
**이 변경은 기존 자동화 테스트로 전혀 걸러지지 않는다.** 소유권 검사 삭제(D-1)와 재고 보상 로직 삭제(D-5)처럼
main에 있던 방어 코드가 사라졌는데도 깨지는 테스트가 하나도 없다는 점이 이번 리뷰의 핵심이다.

| 위험 지점 | 기존 테스트 | 판단 |
|---|---|---|
| R-1 (IDOR) | 없음 | `routes.js` 테스트 파일 자체가 없음 → 전량 수동 |
| R-2 (userId 주입) | 없음 | 동일 → 전량 수동 |
| R-3 (포인트 검증) | 없음 | `order.js` 테스트 파일 없음 → 전량 수동 |
| R-4 (다중 쿠폰 상한) | 없음 | `tests/coupon.test.js`는 `applyCoupon` 1장 경로만 호출(`:10-14`). 신규 `applyCoupons`는 미호출 → 전량 수동 |
| R-5 (저장/재고 순서·보상) | 없음 | main의 보상 로직을 덮던 테스트도 원래 없었음 → 삭제가 무음으로 통과 |
| R-6, R-7 (중복·상한) | 없음 | `applyCoupons` 미커버 |
| R-8 (만료 판정) | `tests/coupon.test.js:13` | `expiresAt:'2020-01-01'` 한 건만 검증(`:8`). 문자열 형식 변형·`null`·타임존 경계 미커버 → 수동 확인 필요 |
| R-9, R-10 (응답·파라미터 호환) | 없음 | 라우트 미커버 |
| R-11~R-14 | 없음 | 라우트·주문 흐름 미커버 |
| (정상 경로) 쿠폰 1장 RATE/FLAT, MIN_AMOUNT | `tests/coupon.test.js:10-11`, `:14` | 유일하게 자동화된 영역. TC-22~24의 수동 우선순위는 낮춰도 됨 |

## 8. 확인 필요

- [ ] ① **쿠폰 만료 당일은 유효인가, 만료인가?** main은 만료 처리, 현재 브랜치는 유효 처리로 동작이 반전됐는데
      커밋 메시지에 근거가 없다. 기획 의도를 확인해야 TC-11의 합격 기준이 정해진다 (`src/coupon.js:13-14`)
- [ ] ② **`GET /orders/:id`의 403 소유권 검사는 왜 삭제되었나?** 상위 미들웨어로 옮겼다면 그 위치를, 아니라면 즉시 복구가 필요하다.
      저장소 내에 대체 검사 코드는 찾지 못했다 (`src/routes.js:27-40`, main `src/routes.js:26-28`)
- [ ] ③ **`req.body.userId` 허용은 의도된 관리자 기능인가?** 관리자 대리 주문이 목적이라면 역할 검사가 필요하고,
      아니라면 `req.user.id`로 되돌려야 한다 (`src/routes.js:8`)
- [ ] ④ **다중 쿠폰의 할인 계산 기준이 "원금 기준 합산"이 맞는가?** 현재는 각 쿠폰이 할인 전 subtotal에 대해 계산된다.
      순차 적용(앞 쿠폰 할인 후 금액에 다음 쿠폰 적용)이 정책이라면 계산식 자체가 틀린 것이다 (`src/coupon.js:34`)
- [ ] ⑤ **`MIN_ORDER_AMOUNT` 판정도 원금 기준이 맞는가?** 3장 적용으로 실결제액이 5,000원 아래로 내려가도
      각 쿠폰은 원금 10,000원 기준으로 최소 금액 조건을 통과한다 (`src/coupon.js:18`)
- [ ] ⑥ **`expiresAt`의 저장 형식과 타임존 기준은 무엇인가?** 실제 DB에 `YYYY-MM-DD`만 들어온다는 보장이 없으면 R-8은 운영에서 재현된다.
      서비스 기준 시간대가 KST인지도 확인해야 한다 (`src/coupon.js:13-14`)
- [ ] ⑦ **구버전 클라이언트 지원 기간이 있는가?** 있다면 `couponCode`/`discount` 폴백이 필요하고, 없다면 강제 업데이트 일정이 선행돼야 한다
      (`src/routes.js:10`, `:16`, `:35`)
- [ ] ⑧ **포인트 사용 상한 정책(결제액의 N%, 1회 최대 금액, 최소 결제 금액)이 있는가?** 현재 코드에는 어떤 상한도 없다 (`src/order.js:38-42`)

## 9. 개선 제안

- **주문 생성을 원자적으로 만들 것.** 현재는 `saveUser`(포인트) → `saveOrder`(주문) → `reserveStock`(재고) 세 저장소를
  트랜잭션 없이 순차 호출하며(`src/order.js:40`, `:56`, `:58`) 중간 실패 시 롤백이 없다.
  최소한 main에 있던 보상 로직(`try/catch` + `releaseStock`)을 복구하고 포인트 차감분도 되돌려야 한다.
  검증은 `reserveStock()`을 **맨 앞**으로 되돌리는 것만으로도 상당 부분 해결된다.
- **`releaseStock`을 `order.js`에서 re-export하지 말 것.** 호출처 없이 export만 남아(`src/order.js:63`) 보상 로직이 살아 있는 것처럼 보인다.
- **실패 경로에 로그가 전혀 없다.** `src/routes.js:21-23`의 catch는 `err.message`를 응답에 실어 보낼 뿐 로그를 남기지 않아,
  TC-08 같은 부분 완료 상태가 운영에서 발생해도 탐지할 방법이 없다. 최소한 주문 ID와 실패 단계를 로깅해야 QA도 재현을 확인할 수 있다.
- **내부 에러 메시지가 그대로 클라이언트에 노출된다** (`src/routes.js:22`). `OUT_OF_STOCK:p1`처럼 내부 상품 ID가 섞여 나가고,
  `req.user`가 없을 때는 `Cannot read properties of undefined` 같은 스택 유래 메시지가 400 바디로 나간다. 에러 코드 매핑을 권한다.
- **주문 ID가 프로세스 전역 카운터 기반의 순차 값이다** (`src/order.js:5`, `:45`). R-1을 고치더라도 ID 추측 가능성은 남고,
  프로세스 재시작 시 `ORD-1`부터 다시 시작해 기존 주문을 덮어쓴다(`db.saveOrder`는 Map `set`, `src/db.js:33`).
- **쿠폰 조회가 루프 내 순차 `await`다** (`src/coupon.js:34` → `src/db.js:16`). 현재는 인메모리라 무시할 수 있으나
  실 DB 전환 시 1주문당 최대 3회의 순차 왕복이 된다. 코드 목록을 한 번에 조회하는 편이 낫다.
- **여러 쿠폰 중 하나가 실패하면 어느 쿠폰인지 알 수 없다.** `applyCoupons`는 첫 실패에서 그대로 예외를 전파해(`src/coupon.js:34`)
  `COUPON_NOT_FOUND`만 남는다. 실패한 코드를 메시지에 포함하면 CS 대응이 쉬워진다.
