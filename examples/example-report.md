<!--
이 스킬로 실제 생성된 리포트 예시입니다.
대상: 샘플 Node.js 주문/쿠폰 서비스의 "쿠폰 중복 적용 + 포인트 결제" 변경 (3파일, +59/-32).
의도적으로 심어둔 결함 14건 중 12건을 잡아냈고, 심지 않은 문제 3건을 추가로 발견했습니다.
-->

# QA 리포트: feature/multi-coupon-points (쿠폰 중복 적용 + 포인트 결제)

| 항목 | 내용 |
|---|---|
| 작성일 | 2026-09-22 |
| 분석 대상 | `feature/multi-coupon-points` 브랜치 (HEAD `a399e31` "feat: 쿠폰 중복 적용 및 포인트 결제 지원") |
| 비교 기준 | `main` @ `6e24aa2` |
| 변경 규모 | 파일 3개 (`src/coupon.js`, `src/order.js`, `src/routes.js`), +59/-32 라인 |
| 분석 제외 | 없음. 변경 3개 파일 전부와 호출 대상(`src/db.js`, `src/inventory.js`), 기존 테스트(`tests/coupon.test.js`)까지 읽었다. |

## 1. 요약

쿠폰을 최대 3장까지 중복 적용하고, 주문 시 포인트를 함께 차감하는 기능이다. 이 과정에서 주문 생성 흐름의 순서가 바뀌었고(저장 → 재고 차감), 기존에 있던 **재고 실패 시 보상 로직(`try/catch` + `releaseStock`)이 통째로 제거**되었으며, **`GET /orders/:id`의 소유권 검증도 함께 삭제**되었다.

QA 관점에서 가장 조심할 것은 세 가지다. 첫째, **금액이 음수로 내려간다.** 할인액·포인트 어느 쪽에도 상한 검증이 없어 결제 총액과 포인트 잔액이 모두 음수가 된다(아래 5장에서 실제 재현 결과 첨부). 둘째, **실패 시 데이터가 반쯤 확정된 상태로 남는다.** 재고 부족으로 요청이 400으로 떨어져도 주문은 `PAID`로 저장되어 있고 포인트는 이미 빠져나간 뒤다. 셋째, **권한 검증 두 군데가 사라졌다.** 요청 body의 `userId`를 그대로 신뢰하고, 주문 상세는 소유자 확인 없이 누구에게나 응답한다.

기존 자동화 테스트는 `applyCoupon()` 1장 경로만 덮고 있어(`tests/coupon.test.js`), **이번 변경분 중 자동화로 검증되는 코드는 사실상 0%**다. 신규 `applyCoupons()`, `createOrder()`의 포인트 분기, 라우트 핸들러 전부 테스트가 없다.

| 우선순위 | 위험 지점 | 테스트 케이스 |
|---|---|---|
| P0 | 5건 (R-1~R-5) | 8건 |
| P1 | 4건 (R-6~R-9) | 6건 |
| P2 | 2건 (R-10~R-11) | 2건 |

**릴리즈 전 필수 확인**: TC-01, TC-02, TC-03, TC-04, TC-05, TC-06, TC-07, TC-08

> **선행 확인 사항**: 5장 "발견된 결함" D-1~D-5는 테스트 이전에 코드 읽기와 재현 스크립트만으로 확정된 결함이다. **이 상태로는 QA를 태워도 대부분의 P0 케이스가 그대로 실패한다.** 개발 수정 후 QA 착수를 권장한다.

## 2. 변경 내용 (기능 관점)

- 주문 시 쿠폰을 **1장 → 최대 3장**까지 받을 수 있게 되었다. 4장 이상 보내면 앞 3장만 조용히 적용된다 (`src/coupon.js:29-39`, 상수 `MAX_COUPONS = 3`은 `src/coupon.js:4`).
- 각 쿠폰의 할인액은 **모두 원래 주문 금액(subtotal) 기준으로 계산되어 단순 합산**된다. 앞 쿠폰이 깎은 금액을 뒷 쿠폰이 반영하지 않는다 (`src/coupon.js:34`, `src/coupon.js:36`).
- 주문 시 **포인트를 함께 사용**할 수 있다. 사용한 만큼 `user.points`에서 차감되고 결제 총액에서도 빠진다 (`src/order.js:38-42`).
- **주문 처리 순서가 바뀌었다.** main에서는 `재고 차감 → 주문 저장(실패 시 재고 복구)`였으나, 이제 `주문 저장 → 재고 차감`이고 실패 시 복구 로직이 없다 (`src/order.js:56-58`, main의 `src/order.js:29-52` 대비).
- **API 응답 필드가 바뀌었다.** `discount`(숫자) 가 `discounts`(적용 쿠폰 배열 `[{code, amount}]`)로 대체되고 `pointsUsed`가 추가되었다. `POST /orders`, `GET /orders/:id` 양쪽 모두 (`src/routes.js:16-17`, `src/routes.js:35-36`).
- **요청 파라미터가 바뀌었다.** `couponCode`(단수 문자열) → `couponCodes`(배열). 구 클라이언트가 보내던 `couponCode`는 읽히지 않는다 (`src/routes.js:10`).
- `POST /orders`가 주문 주체를 **요청 body의 `userId`에서 먼저 읽는다.** 없을 때만 인증 세션(`req.user.id`)으로 떨어진다 (`src/routes.js:8`).
- `GET /orders/:id`의 **소유권 검증(403 FORBIDDEN)이 삭제**되었다 (`src/routes.js:27-39`, main의 `src/routes.js:26-28` 대비).

## 3. 회귀 영향 범위

변경된 공통 코드와 그 호출 지점. QA는 신규 기능뿐 아니라 아래 기존 기능도 반드시 확인해야 한다.

| 변경된 대상 | 호출/사용 지점 | 영향 받는 기능 |
|---|---|---|
| `applyCoupon()` 만료 판정 로직 (`src/coupon.js:13-14`) | `src/coupon.js:34`, `tests/coupon.test.js:10-14` | **쿠폰 1장만 쓰는 기존 주문 전체.** 만료 기준이 로컬시각 → UTC 문자열 비교로 바뀌어 기존 쿠폰의 유효기간 판정이 달라진다 |
| `createOrder()` 시그니처 (`src/order.js:17`) — 3번째 인자가 문자열 → 배열 | `src/routes.js:7-12` | 주문 생성 전 경로. 배열이 아닌 값이 들어오면 문자 단위로 쪼개져 `COUPON_NOT_FOUND`가 난다 |
| 주문 저장/재고 차감 순서 (`src/order.js:56-58`) | `src/inventory.js:4-15` (`reserveStock`) | **재고 관리 전체.** 쿠폰·포인트를 안 쓰는 일반 주문도 동일한 새 순서를 탄다 |
| `releaseStock` 보상 호출 제거 (`src/order.js:58`) | `src/order.js:63`에서 re-export만 되고 **호출자 없음** (grep 확인) | 재고 복구 경로가 코드 전체에서 사라짐 |
| order 레코드 스키마 (`src/order.js:44-55`) — `coupons`, `pointsUsed` 필드 추가 | `src/routes.js:16-17`, `src/routes.js:35-36` | 이 필드가 없는 기존 주문 레코드를 조회하면 응답에서 해당 키가 누락된다 |
| `POST /orders` 응답 바디 (`src/routes.js:13-20`) | API 클라이언트 (저장소 내 프런트엔드 코드 없음) | `discount`를 읽던 모든 클라이언트 |
| `GET /orders/:id` 응답 + 권한 (`src/routes.js:27-39`) | API 클라이언트 | 주문 상세 조회 권한 |

## 4. 위험 지점

### R-1. 여러 쿠폰의 할인액이 원 주문금액 기준으로 합산되어 결제 총액이 음수가 된다 [P0]

- **근거**: `src/coupon.js:29-39` (특히 `:34`, `:36`), `src/order.js:36`
- **무슨 일이 일어나는가**: `applyCoupons()`는 루프를 돌며 매번 **같은 `subtotal`을 넘겨** `applyCoupon()`을 호출하고 결과를 `totalDiscount += amount`로 더한다(`src/coupon.js:34-36`). 순차 할인이 아니다. 따라서 50% 정률 쿠폰 3장이면 할인율이 150%가 된다. `src/order.js:36`의 `total = subtotal - discount`에는 하한(0) 클램프가 없다.
- **영향**: 10,000원 주문에 50% 쿠폰 3장 → `discount = 15,000`, `total = -5,000`. 결제 시스템에 음수 금액이 전달되고, 주문은 그대로 `PAID`로 저장된다. 정산·환불 오류로 직결된다.
- **부수 효과**: `MIN_ORDER_AMOUNT` 검증(`src/coupon.js:18`)은 항상 **원래 subtotal**로만 이루어진다. 실질 결제액이 0원 이하가 되어도 최소주문금액 조건은 통과한다.
- **관련 테스트 케이스**: TC-01, TC-02, TC-09

### R-2. 포인트 사용액에 잔액 검증도 결제금액 상한 검증도 없다 [P0]

- **근거**: `src/order.js:38-42`
- **무슨 일이 일어나는가**: `if (usePoints > 0)` 하나만 통과하면 `user.points -= usePoints` 후 곧바로 `db.saveUser(user)`로 영속화한다. **보유 포인트와 비교하는 코드가 없고**, `total -= usePoints`에도 상한이 없다.
- **영향**: 보유 포인트가 100점인 사용자가 999,999를 보내면 잔액이 **-999,899**이 되고 결제 총액도 음수가 된다. 포인트 잔액이 음수로 영속되면 이후 모든 주문·조회가 비정상 상태를 물고 간다. 사실상 무한 결제 우회다.
- **추가**: `user` 객체는 `db.getUser()`가 Map에 저장된 **원본 참조를 그대로 반환**하므로(`src/db.js:7-9`), `saveUser`가 실패하더라도 메모리상의 잔액은 이미 깎인 뒤다. 롤백 경로가 없다.
- **관련 테스트 케이스**: TC-03, TC-04, TC-10

### R-3. 재고 차감 실패 시 주문은 PAID로 남고 포인트는 이미 차감된 상태가 된다 [P0]

- **근거**: `src/order.js:56-60`. main의 `src/order.js:29-52`(제거된 `try/catch` + `releaseStock`) 대비
- **무슨 일이 일어나는가**: main에서는 `reserveStock()`을 먼저 호출하고, 주문 저장이 실패하면 `catch`에서 `releaseStock(items)`으로 재고를 되돌렸다. 이번 변경에서 순서가 **`db.saveOrder(order)` → `reserveStock(items)`**로 뒤집혔고 `try/catch`가 통째로 삭제되었다. `reserveStock()`은 재고가 모자라면 `OUT_OF_STOCK:<productId>`를 던진다(`src/inventory.js:7-9`).
- **영향**: 재고가 없으면 사용자는 400 에러를 받는데, DB에는 `status: 'PAID'` 주문이 이미 저장되어 있고(`src/order.js:53`) 포인트도 이미 빠져나간 뒤다(`src/order.js:39-40`). 사용자 입장에서는 "실패했는데 포인트가 사라진" 상태이고, 운영 입장에서는 배송 불가능한 결제완료 주문이 쌓인다. 복구 경로는 코드에 존재하지 않는다 — `releaseStock`은 `src/order.js:63`에서 export만 될 뿐 호출자가 없다(grep 확인).
- **관련 테스트 케이스**: TC-05, TC-06

### R-4. POST /orders가 요청 body의 userId를 인증 정보보다 우선 신뢰한다 [P0]

- **근거**: `src/routes.js:8` — `req.body.userId || req.user.id`
- **무슨 일이 일어나는가**: 인증 세션(`req.user.id`)은 body에 `userId`가 **없을 때만** 쓰인다. 로그인한 사용자가 body에 타인의 `userId`를 넣으면 그 사람 명의로 주문이 생성되고, 그 사람의 포인트가 차감된다(`src/order.js:18`, `src/order.js:39`).
- **영향**: 인증 우회 + 타인 자산(포인트) 임의 소모. main에는 이 경로가 없었다(main `src/routes.js:7`은 `req.user.id`만 사용).
- **관련 테스트 케이스**: TC-07

### R-5. GET /orders/:id의 소유권 검증이 삭제되어 남의 주문을 조회할 수 있다 [P0]

- **근거**: `src/routes.js:27-39`. main의 `src/routes.js:26-28`에 있던 `if (order.userId !== req.user.id) return res.status(403)`가 제거됨
- **무슨 일이 일어나는가**: 주문 ID만 알면 소유자와 무관하게 200 응답과 함께 금액·상태·쿠폰 내역이 반환된다. 주문 ID는 `ORD-${seq++}` 형태의 **순차 증가값**이므로(`src/order.js:5`, `src/order.js:45`) 열거가 매우 쉽다.
- **영향**: 전형적인 IDOR. 타인의 주문 금액/포인트 사용 내역이 열거 가능한 ID로 전부 노출된다. 이번 변경의 기능 요구사항(쿠폰·포인트)과 무관한 삭제로 보여 **실수일 가능성이 높다** — 8장에서 담당자 확인 항목으로 올렸다.
- **관련 테스트 케이스**: TC-08

### R-6. 동일한 쿠폰 코드를 중복 투입해도 걸러지지 않는다 [P1]

- **근거**: `src/coupon.js:33-37`
- **무슨 일이 일어나는가**: 루프는 넘어온 `codes` 배열을 그대로 순회할 뿐 **중복 제거를 하지 않으며**, 사용자별 쿠폰 보유/사용 이력을 확인하는 코드도 `src/coupon.js`와 `src/db.js` 어디에도 없다. `applyCoupon()`은 `db.getCoupon(code)`로 쿠폰 정의만 읽는다(`src/coupon.js:8`).
- **영향**: `["FLAT1000","FLAT1000","FLAT1000"]`을 보내면 1,000원 쿠폰 1장으로 3,000원을 할인받는다. R-1과 결합하면 음수 총액에 더 쉽게 도달한다.
- **관련 테스트 케이스**: TC-11

### R-7. 쿠폰 만료 판정이 문자열 비교 + UTC 기준으로 바뀌어 유효기간이 달라진다 [P1]

- **근거**: `src/coupon.js:13-14`. main은 `const today = new Date(); if (new Date(coupon.expiresAt) < today)`
- **무슨 일이 일어나는가**: 세 가지가 동시에 바뀌었다.
  1. **만료일 당일의 판정이 뒤집혔다.** main에서는 `new Date('2026-09-22')`(= UTC 자정)가 현재시각보다 이르므로 만료일 당일이면 이미 만료였다. 지금은 `'2026-09-22' < '2026-09-22'` → `false`라 **만료일 당일 하루가 통째로 더 유효해졌다** (node 실행으로 확인).
  2. **기준 시각이 UTC가 되었다.** `new Date().toISOString().slice(0,10)`은 UTC 날짜다. KST(UTC+9) 기준 9월 23일 00:00~09:00 사이에도 UTC 날짜는 아직 09-22라 09-22 만료 쿠폰이 계속 통과한다. 1번과 합치면 KST 기준 최대 약 33시간 연장된다.
  3. **`expiresAt` 형식에 의존하게 되었다.** 문자열 비교이므로 `YYYY-MM-DD`가 아닌 값은 판정이 무너진다. `'2026/09/22' < '2026-09-22'`는 `false`(구분자 `/`의 코드포인트가 `-`보다 큼) → **슬래시 형식으로 저장된 쿠폰은 영구히 만료되지 않는다**. `Date` 객체나 epoch 숫자로 저장된 경우도 마찬가지로 오판정된다. main의 `new Date(...)` 파싱은 이런 형식을 흡수했다.
- **영향**: 종료된 프로모션 쿠폰이 계속 사용 가능 → 예산 초과. 운영 DB의 `expiresAt` 저장 형식에 따라 영향 범위가 달라지므로 8장에서 확인 항목으로 올렸다.
- **관련 테스트 케이스**: TC-12, TC-13

### R-8. 4장 이상 보내면 초과분이 조용히 무시된다 [P1]

- **근거**: `src/coupon.js:33` — `codes.slice(0, MAX_COUPONS)`
- **무슨 일이 일어나는가**: 초과 쿠폰은 에러도 경고도 없이 잘려나간다. 응답의 `discounts` 배열에는 적용된 3장만 담기므로(`src/routes.js:16`), 클라이언트가 응답을 비교하지 않으면 사용자는 4장 다 적용된 줄 안다.
- **영향**: 사용자가 가장 유리한 조합을 고를 수 없고(순서대로 앞 3장), 문의·클레임 요인이 된다. 금액 자체는 틀리지 않는다.
- **관련 테스트 케이스**: TC-14

### R-9. API 요청/응답 계약이 호환성 없이 바뀌어 구 클라이언트가 조용히 오동작한다 [P1]

- **근거**: `src/routes.js:10` (`couponCodes`), `src/routes.js:16` / `src/routes.js:35` (`discount` → `discounts`)
- **무슨 일이 일어나는가**: 두 방향 모두 폴백이 없다.
  - **요청**: 구 클라이언트가 보내는 `couponCode`(단수)를 읽는 코드가 사라졌다. `req.body.couponCodes || []`는 `[]`가 되어 쿠폰 없는 주문이 **에러 없이 정가로** 생성된다.
  - **응답**: `discount`(숫자)가 사라지고 `discounts`(배열)가 왔다. 구 클라이언트의 할인 금액 표시가 `undefined`가 된다.
- **영향**: 배포 직후 구버전 앱/캐시된 프런트엔드 사용자가 할인 없이 결제하게 된다. 실패가 아니라 **조용한 금액 차이**라 발견이 늦다.
- **관련 테스트 케이스**: TC-15, TC-16

### R-10. `createOrder()`를 직접 호출할 때 `couponCodes`에 배열이 아닌 값이 들어가면 깨진다 [P2]

- **근거**: `src/order.js:17`, `src/order.js:30`, `src/coupon.js:33`
- **무슨 일이 일어나는가**: 기본값 `= []`는 `undefined`일 때만 적용된다. `null`이 넘어오면 `src/order.js:30`의 `couponCodes.length`에서 TypeError가 난다. 문자열 `"SUMMER"`가 넘어오면 `.length > 0`을 통과하고 `"SUMMER".slice(0,3)` → `"SUM"`을 문자 단위로 순회해 `'S'`, `'U'`, `'M'`을 쿠폰 코드로 조회한다(node 확인) → `COUPON_NOT_FOUND`.
- **영향**: 라우트 경유로는 `|| []`에 막혀 재현되지 않지만, `createOrder`는 `src/order.js:63`에서 공개 export되어 있어 배치·어드민 등 다른 호출자가 생기면 노출된다. 현재 저장소 내 호출자는 `src/routes.js:7` 하나뿐이다.
- **관련 테스트 케이스**: TC-17

### R-11. `pointsUsed`에 정수/소수 검증이 없다 [P2]

- **근거**: `src/order.js:38-41`, `src/routes.js:11`
- **무슨 일이 일어나는가**: `usePoints > 0`만 확인하므로 `0.5`, `1.7` 같은 소수가 그대로 차감되고 총액에서 빠진다. 음수는 `> 0` 조건에 걸러지지만 **에러 없이 무시**되어 사용자에게 아무 피드백이 없다.
- **영향**: 포인트 잔액에 소수점이 생겨 이후 표시·정산이 어긋난다.
- **관련 테스트 케이스**: TC-18

## 5. 발견된 결함

아래는 테스트 이전에 이미 확정된 결함이다. D-1~D-3은 스크립트로 직접 재현해 값을 확인했다(소스 수정 없음, 스크래치 스크립트에서 `createOrder()` 호출).

| ID | 내용 | 위치 | 심각도 |
|---|---|---|---|
| D-1 | 50% 정률 쿠폰 3장을 10,000원 주문에 적용하면 `discount=15000`, `total=-5000`. 결제 총액이 음수로 저장된다 | `src/coupon.js:34-36`, `src/order.js:36` | P0 |
| D-2 | 보유 100점인 사용자가 `usePoints=999999`로 주문하면 잔액이 `-999899`로 영속되고 `total=-989999`가 된다. 잔액 검증 자체가 없다 | `src/order.js:38-42` | P0 |
| D-3 | 재고 0인 상품 주문 시 `OUT_OF_STOCK:p2`가 던져지지만, 주문은 이미 `status:'PAID'`로 저장되어 있고 포인트 500점도 차감된 뒤다(재현 시 잔액 500→0). `releaseStock`은 `src/order.js:63`에서 export만 되고 호출되는 곳이 없다 | `src/order.js:56-60`, `src/order.js:63` | P0 |
| D-4 | `POST /orders`가 `req.body.userId`를 인증 세션보다 우선 사용해 타인 명의 주문·타인 포인트 차감이 가능하다 | `src/routes.js:8` | P0 |
| D-5 | `GET /orders/:id`에서 소유권 검증(403)이 삭제되어 순차 증가 ID(`ORD-1`, `ORD-2`…)만 알면 타인 주문 상세를 조회할 수 있다 | `src/routes.js:27-39`, `src/order.js:45` | P0 |
| D-6 | 동일 쿠폰 코드를 중복 투입해도 걸러지지 않아 한 장을 3번 적용할 수 있다 | `src/coupon.js:33-37` | P1 |
| D-7 | 만료 판정 변경으로 `expiresAt`이 `YYYY-MM-DD`가 아닌 쿠폰(예: `2026/09/22`)은 영구히 만료되지 않는다 | `src/coupon.js:13-14` | P1 |

수정은 이 리포트의 범위가 아니다. 위 항목은 개발 담당자에게 전달해 판단을 받아야 한다.

## 6. 테스트 케이스

> **공통 사전조건 / 실행 방법**
>
> 이 저장소에는 HTTP 서버를 띄우는 부트스트랩 코드가 없다. `src/routes.js`는 핸들러 함수 2개를 export할 뿐이고(`src/routes.js:42`), express 등 프레임워크 의존성도 `package.json`에 없다. 따라서 **UI나 실제 엔드포인트로는 도달할 수 없으며**, 아래 절차는 모두 Node 스크립트에서 직접 호출하는 방식으로 작성했다. 저장소는 인메모리 저장소(`src/db.js`)를 쓰므로 **스크립트 1회 실행 = 1회 세션**이고, 프로세스를 재시작하면 모든 데이터가 초기화된다.
>
> 각 TC 앞에 붙이는 공통 셋업 (`SETUP`):
>
> ```js
> const db = require('./src/db');
> const { createOrder } = require('./src/order');
> const { postOrder, getOrderDetail } = require('./src/routes');
> db._raw.users.set('u1', { id: 'u1', points: 1000 });
> db._raw.users.set('u2', { id: 'u2', points: 5000 });
> db._raw.coupons.set('R50',    { code:'R50',    type:'RATE', value:0.5,  expiresAt:'2099-12-31' });
> db._raw.coupons.set('R10',    { code:'R10',    type:'RATE', value:0.1,  expiresAt:'2099-12-31' });
> db._raw.coupons.set('F1000',  { code:'F1000',  type:'FLAT', value:1000, expiresAt:'2099-12-31' });
> await db.setStock('p1', 100);   // 상품 단가는 항상 1000원 (src/db.js:20-22)
> ```
>
> 라우트 핸들러 호출 시 `res`는 `{ status(c){this.code=c; return this;}, json(b){this.body=b;} }` 형태의 목으로 대체한다.

| TC | P | 검증 항목 | 사전조건 | 절차 | 기대 결과 | 근거 | 자동화 |
|---|---|---|---|---|---|---|---|
| TC-01 | P0 | 다중 정률 쿠폰으로 할인액이 주문액을 초과 | SETUP. `R50`(50% 정률) 쿠폰, 상품 p1 10개 = 10,000원 | 1) SETUP 실행 2) `await createOrder('u1', [{productId:'p1', quantity:10}], ['R50','R50','R50'], 0)` 3) 반환 객체의 `subtotal`, `discount`, `total` 출력 | 결제 총액이 **0원 미만으로 내려가지 않아야** 한다. 현재는 `discount=15000`, `total=-5000`으로 **실패한다**(D-1). 기대 동작(0 클램프 / 에러 코드)은 8장 확인 필요 항목 | `src/coupon.js:34-36`, `src/order.js:36` | 없음 |
| TC-02 | P0 | 다중 정액 쿠폰 합산이 주문액 초과 | SETUP. 상품 p1 6개 = 6,000원 (MIN_ORDER_AMOUNT 5,000 충족) | 1) SETUP 실행 2) `createOrder('u1', [{productId:'p1', quantity:6}], ['F1000','F1000','F1000'], 0)` 3) `total` 확인 | `total = 3000`. 음수가 아님을 확인하고 `discounts` 배열에 3건이 각각 `amount:1000`으로 담기는지 확인 | `src/coupon.js:29-39`, `src/routes.js:16` | 없음 |
| TC-03 | P0 | 보유 포인트를 초과하는 포인트 사용 | SETUP. `u1`의 보유 포인트 1,000점. 상품 p1 10개 = 10,000원 | 1) SETUP 실행 2) `createOrder('u1', [{productId:'p1', quantity:10}], [], 5000)` 3) `db._raw.users.get('u1').points` 출력 | 잔액 부족 에러로 **거부**되어야 하고 주문이 생성되지 않아야 한다. 현재는 주문이 `PAID`로 생성되고 잔액이 **-4000**이 된다 — **실패 예상**(D-2) | `src/order.js:38-42` | 없음 |
| TC-04 | P0 | 결제금액을 초과하는 포인트 사용 | SETUP. `u2`의 보유 포인트 5,000점(충분). 상품 p1 3개 = 3,000원 | 1) SETUP 실행 2) `createOrder('u2', [{productId:'p1', quantity:3}], [], 5000)` 3) 반환 객체의 `total` 확인 | 잔액은 충분하지만 결제금액(3,000원)을 넘는 포인트는 거부되거나 3,000으로 상한 처리되어야 한다. 현재 `total=-2000` — **실패 예상** | `src/order.js:41` | 없음 |
| TC-05 | P0 | 재고 부족 시 주문 레코드가 남지 않아야 함 | SETUP 후 `await db.setStock('p2', 0)` 추가 | 1) SETUP 실행 2) `try { await createOrder('u1', [{productId:'p2', quantity:1}], [], 0) } catch(e) { console.log(e.message) }` 3) `[...db._raw.orders.values()]` 출력 | `OUT_OF_STOCK:p2`가 던져지고 **저장된 주문이 0건**이어야 한다. 현재는 `status:'PAID'` 주문이 1건 남는다 — **실패 예상**(D-3) | `src/order.js:56-58`, `src/inventory.js:7-9` | 없음 |
| TC-06 | P0 | 재고 부족 시 차감된 포인트가 복구되어야 함 | SETUP 후 `db.setStock('p2', 0)`. `u1` 포인트 1,000점 | 1) SETUP 실행 2) `createOrder('u1', [{productId:'p2', quantity:1}], [], 500)`을 try/catch로 호출 3) `db._raw.users.get('u1').points` 출력 | 예외 발생 후 잔액이 **1000으로 유지**되어야 한다. 현재는 **500**으로 남는다 — **실패 예상**(D-3) | `src/order.js:38-42`, `src/order.js:58` | 없음 |
| TC-07 | P0 | body의 userId로 타인 명의 주문 생성 (인증 우회) | SETUP. `u1`으로 로그인한 상태를 가정 | 1) SETUP 실행 2) `req = { user:{id:'u1'}, body:{ userId:'u2', items:[{productId:'p1',quantity:5}], usePoints:3000 } }` 구성 3) `await postOrder(req, res)` 4) 응답 코드와 `db._raw.users.get('u2').points` 확인 | 세션 주체(`u1`)로 주문되거나 요청이 거부되어야 한다. 현재는 `u2` 명의로 201이 떨어지고 `u2`의 포인트가 3,000점 차감된다 — **실패 예상**(D-4) | `src/routes.js:8`, `src/order.js:18` | 없음 |
| TC-08 | P0 | 타인 주문 상세 조회 차단 (IDOR) | SETUP. `u2`가 주문 1건을 생성해 ID 확보 | 1) SETUP 실행 2) `const o = await createOrder('u2', [{productId:'p1',quantity:5}], [], 0)` 3) `req = { user:{id:'u1'}, params:{id:o.id} }` 4) `await getOrderDetail(req, res)` 5) 응답 코드 확인 | **403 FORBIDDEN**이어야 한다(main 동작). 현재는 200과 함께 `u2`의 주문 상세가 반환된다 — **실패 예상**(D-5). 추가로 `ORD-1`, `ORD-2` 순차 ID로 열거가 가능한지도 확인 | `src/routes.js:27-39` | 없음 |
| TC-09 | P1 | 정률 + 정액 쿠폰 혼합 시 계산 기준 | SETUP. 상품 p1 10개 = 10,000원 | 1) SETUP 실행 2) `createOrder('u1', [{productId:'p1',quantity:10}], ['R10','F1000'], 0)` 3) `discount`와 `discounts` 배열 확인 | 두 쿠폰 모두 **원래 금액 10,000 기준**으로 계산되어 `R10`=1000, `F1000`=1000, `discount=2000`, `total=8000`. 순차 적용(9,000원에 대해 F1000 적용)이 기획 의도인지 확인 필요 — 8장 참조 | `src/coupon.js:34`, `src/coupon.js:23` | 없음 |
| TC-10 | P1 | 쿠폰 + 포인트 동시 사용 시 합산 순서 | SETUP. `u1` 포인트 1,000점. 상품 p1 10개 = 10,000원 | 1) SETUP 실행 2) `createOrder('u1', [{productId:'p1',quantity:10}], ['R10'], 1000)` 3) `subtotal`/`discount`/`pointsUsed`/`total` 4개 값 전부 확인 | `subtotal=10000`, `discount=1000`, `pointsUsed=1000`, `total=8000`, `u1` 잔액 0. 쿠폰 할인이 **포인트 차감 전 금액** 기준으로 계산되는지 확인 | `src/order.js:36-42` | 없음 |
| TC-11 | P1 | 동일 쿠폰 코드 중복 투입 | SETUP. 상품 p1 10개 = 10,000원 | 1) SETUP 실행 2) `createOrder('u1', [{productId:'p1',quantity:10}], ['F1000','F1000','F1000'], 0)` 3) `discount`와 `discounts` 길이 확인 | 중복은 1장으로 합쳐지거나 에러가 나야 한다. 현재는 `discount=3000`, `discounts` 3건 — **실패 예상**(D-6) | `src/coupon.js:33-37` | 없음 |
| TC-12 | P1 | 만료 당일 쿠폰의 유효성 (main 대비 회귀) | SETUP. 오늘 날짜(UTC 기준)를 `YYYY-MM-DD`로 구해 `expiresAt`에 넣은 쿠폰 등록: `db._raw.coupons.set('TODAY', {code:'TODAY', type:'FLAT', value:1000, expiresAt: new Date().toISOString().slice(0,10)})` | 1) SETUP 실행 2) `const { applyCoupon } = require('./src/coupon')` 3) `await applyCoupon('TODAY', 10000)` 호출 | 현재 브랜치는 `1000`을 반환(유효)한다. **main에서는 `COUPON_EXPIRED`로 거부된다.** 만료일 당일을 유효로 볼지 기획 확인 필요 — 8장 참조 | `src/coupon.js:13-14` | 없음 |
| TC-13 | P1 | `expiresAt` 형식이 `YYYY-MM-DD`가 아닌 쿠폰 | SETUP. `db._raw.coupons.set('SLASH', {code:'SLASH', type:'FLAT', value:1000, expiresAt:'2020/01/01'})` 등록 (과거 날짜) | 1) SETUP 실행 2) `await applyCoupon('SLASH', 10000)` 호출 | 명백히 만료된 쿠폰이므로 `COUPON_EXPIRED`여야 한다. 현재는 `1000`을 반환한다(문자열 비교에서 `'2020/01/01' < '2026-09-22'`가 false) — **실패 예상**(D-7). 운영 DB에 이런 형식이 있는지는 8장에서 확인 | `src/coupon.js:13-14` | 없음 |
| TC-14 | P1 | 쿠폰 4장 이상 투입 시 초과분 처리 | SETUP. 쿠폰 4개 코드 준비 | 1) SETUP 실행 2) `createOrder('u1', [{productId:'p1',quantity:10}], ['R10','F1000','R10','F1000'], 0)` 3) `discounts` 배열 길이와 포함 코드 확인 | 초과분이 있음을 알리는 에러나 응답 필드가 있어야 한다. 현재는 앞 3장만 조용히 적용되고 4번째는 응답 어디에도 나타나지 않는다 | `src/coupon.js:33`, `src/coupon.js:4` | 없음 |
| TC-15 | P1 | 구 클라이언트 요청 호환성 (`couponCode` 단수) | SETUP. main 시절 클라이언트가 보내던 형태 | 1) SETUP 실행 2) `req = { user:{id:'u1'}, body:{ items:[{productId:'p1',quantity:10}], couponCode:'F1000' } }` 3) `await postOrder(req, res)` 4) 응답의 `discounts`/`total` 확인 | 할인이 적용되거나 명확한 에러가 나야 한다. 현재는 **에러 없이 `discounts:[]`, `total=10000`(정가)** 로 주문이 성사된다 | `src/routes.js:10` | 없음 |
| TC-16 | P1 | 응답 필드 변경으로 인한 구 클라이언트 표시 | SETUP | 1) SETUP 실행 2) `postOrder`로 쿠폰 1장 주문 생성 3) 응답 바디 키 목록 출력 4) `getOrderDetail`로 같은 주문 조회 후 키 목록 출력 | 두 응답 모두 `discount` 키가 **없고** `discounts`(배열) + `pointsUsed`가 있음을 확인. `discount`를 읽는 클라이언트가 있는지 배포 전 확인 필요 | `src/routes.js:16-17`, `src/routes.js:35-36` | 없음 |
| TC-17 | P2 | `couponCodes`에 배열이 아닌 값 전달 | SETUP. `createOrder`를 직접 호출 | 1) SETUP 실행 2) `createOrder('u1', [{productId:'p1',quantity:10}], 'F1000', 0)` (문자열) 호출 3) `createOrder('u1', [...], null, 0)` 호출 | 문자열: 현재 `'F10'`이 문자 단위로 순회되어 `COUPON_NOT_FOUND`. null: `couponCodes.length`에서 TypeError. 타입 검증 에러(예: `INVALID_COUPON_CODES`)로 통일되어야 한다 | `src/order.js:17`, `src/order.js:30`, `src/coupon.js:33` | 없음 |
| TC-18 | P2 | 포인트 값 경계 (소수·음수·0) | SETUP. `u1` 포인트 1,000점 | 1) SETUP 실행 2) `usePoints`를 각각 `0`, `-500`, `0.5`, `"500"`(문자열)로 바꿔가며 `createOrder('u1', [{productId:'p1',quantity:10}], [], X)` 호출 3) 매회 `pointsUsed`와 `db._raw.users.get('u1').points` 확인 | `0`: 포인트 미사용. `-500`: 거부되어야 하나 현재는 조용히 무시(피드백 없음). `0.5`: 거부되어야 하나 현재는 잔액이 `999.5`가 된다. `"500"`: 숫자로 강제변환되어 통과한다 | `src/order.js:38-41`, `src/routes.js:11` | 없음 |

- `P`: P0(릴리즈 차단) / P1(주요 기능) / P2(경계·부가)
- `자동화`: 없음 / 부분 / 있음 + 테스트 파일 위치

## 7. 자동화 커버리지

저장소의 유일한 테스트는 `tests/coupon.test.js`이고, `npm test`는 이 파일 하나만 실행한다(`package.json`의 `"test": "node tests/coupon.test.js"`). 현재 브랜치에서 실행하면 **통과한다**(`ok`) — 즉 **기존 테스트는 이번 변경의 결함을 하나도 잡지 못한다.** 이번 브랜치에 추가된 테스트는 없다(collect_context.sh의 "변경에 포함된 테스트 파일" 결과 비어 있음).

| 위험 지점 | 기존 테스트 | 판단 |
|---|---|---|
| R-1 (다중 쿠폰 합산) | 없음. `tests/coupon.test.js`는 `applyCoupon()` 단건만 호출(`:10-14`) | `applyCoupons()`를 호출하는 테스트가 전무 → 전량 수동 확인 |
| R-2 (포인트 검증) | 없음 | `createOrder()`를 다루는 테스트가 전무 → 전량 수동 확인 |
| R-3 (재고 실패 보상) | 없음 | main 시절의 `try/catch` 보상 로직에도 테스트가 없었음. 제거가 조용히 통과한 원인 |
| R-4 / R-5 (권한) | 없음 | 라우트 핸들러 테스트가 전무. **403 검증 삭제가 어떤 테스트도 깨뜨리지 않았다** → 리뷰에서 놓치기 쉬운 형태 |
| R-6 (쿠폰 중복) | 없음 | 수동 확인 필요 |
| R-7 (만료 판정) | **부분** — `tests/coupon.test.js:8`, `:13`이 `expiresAt:'2020-01-01'` 만료 케이스를 검증 | 과거/미래로 한참 떨어진 값(2020, 2099)만 써서 **만료 당일 경계와 타임존을 전혀 덮지 못한다.** 이 테스트가 통과한다고 R-7이 안전한 게 아니다 |
| R-8 / R-9 / R-10 / R-11 | 없음 | 전량 수동 확인 |

## 8. 확인 필요

코드만으로 판단할 수 없어 기획·개발 담당자 확인이 필요한 항목.

- [ ] **`GET /orders/:id`의 403 소유권 검증 삭제가 의도된 것인가?** 쿠폰·포인트 기능과 무관한 삭제라 실수로 보인다. 의도된 것이라면 어떤 접근 제어로 대체되는지 확인해야 한다 (`src/routes.js:27-39`, main의 `src/routes.js:26-28`)
- [ ] **`req.body.userId`를 우선 사용하는 것이 의도된 것인가?** 어드민 대리주문 같은 요구가 있다면 별도 권한 검사가 필요하다 (`src/routes.js:8`)
- [ ] **다중 쿠폰의 계산 기준이 "원 주문금액 병렬" vs "순차 차감" 중 무엇인가?** 현재 코드는 병렬(원 금액 기준 합산)이다. 순차라면 `applyCoupons()`의 루프에서 남은 금액을 넘겨야 한다 (`src/coupon.js:34`)
- [ ] **할인·포인트 적용 후 결제 총액의 하한이 얼마인가?** 0원인지, 최소 결제금액이 따로 있는지에 따라 TC-01·TC-04의 기대 결과가 달라진다 (`src/order.js:36`, `src/order.js:41`)
- [ ] **쿠폰 만료일 "당일"은 유효한가, 만료인가?** 이번 변경으로 판정이 뒤집혔다. 또한 기준 시각을 UTC로 둘지 KST로 둘지 확정이 필요하다 (`src/coupon.js:13-14`)
- [ ] **운영 DB의 `coupon.expiresAt` 저장 형식이 전부 `YYYY-MM-DD` 문자열인가?** 슬래시 형식·`Date` 객체·epoch 숫자가 섞여 있으면 D-7의 영향 범위가 커진다 (`src/coupon.js:14`)
- [ ] **동일 쿠폰 중복 사용과 사용자별 쿠폰 보유/사용 이력 검증은 어디서 하는가?** 현재 코드베이스 어디에도 없다. 별도 시스템이 앞단에 있는지 확인 필요 (`src/coupon.js:8`, `src/db.js:16-18`)
- [ ] **배포 시 구버전 클라이언트가 남아 있는가?** 남아 있다면 `couponCode`/`discount` 하위호환 처리 또는 API 버저닝이 필요하다 (`src/routes.js:10`, `src/routes.js:16`)
- [ ] **기존 주문 레코드(`coupons`/`pointsUsed` 필드가 없는 데이터)의 조회 응답을 어떻게 처리할 것인가?** 현재 코드에서는 해당 키가 응답에서 누락된다. 이 저장소는 인메모리 저장소(`src/db.js:1-5`)라 재현되지 않지만, 실제 영속 저장소를 쓰는 환경에서는 확인이 필요하다 (`src/routes.js:35-36`)

## 9. 개선 제안

테스트 범위 밖이지만 남겨둘 만한 것.

- **실패 경로에 로그가 없다.** `src/routes.js:21-23`의 `catch`는 `err.message`를 400 응답으로 내보낼 뿐 로깅하지 않는다. QA가 재현한 실패를 서버 쪽에서 교차 확인할 방법이 없고, 운영에서도 원인 추적이 어렵다.
- **내부 에러 메시지가 그대로 클라이언트에 노출된다.** `src/routes.js:22`가 `err.message`를 그대로 실어 보내므로 `OUT_OF_STOCK:p2`처럼 내부 상품 ID가 응답에 노출된다. 또한 `USER_NOT_FOUND`, `COUPON_NOT_FOUND` 등 원인이 다른 에러가 전부 400으로 뭉뚱그려진다(404/409가 적절한 경우 포함).
- **`releaseStock`이 `src/order.js:63`에서 re-export되지만 호출자가 없다.** 보상 로직을 되살릴 계획이 없다면 export를 정리하는 편이 오해를 줄인다.
- **`discount` 필드가 주문 레코드에는 여전히 저장되지만(`src/order.js:49`) 응답에서는 빠졌다.** 의도적이라면 문제없으나, 운영 조회 도구가 이 필드를 쓰는지 확인해두면 좋다.
- **자동화 테스트가 이번 변경분을 전혀 덮지 않는다.** 최소한 D-1~D-6에 해당하는 케이스(음수 총액, 포인트 초과, 재고 실패 보상, 권한 2건)는 회귀 테스트로 고정해두는 것을 권한다.
