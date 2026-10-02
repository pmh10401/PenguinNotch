# Stock Forecast Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 예측 이력을 보존하면서 같은 거래일 정규장 종가의 통합 평가와 봉별 과거 재현을 macOS·Windows에 제공한다.

**Architecture:** 원본 저널과 Codex 저장소는 읽기 어댑터로 연결하고, 재현 입력·결과는 별도 실행 폴더에 저장한다. 기존 GBM 계산과 토스 전송을 재사용한다. 동일 입력의 기준선 비교와 선택 모델 교집합을 구분한다.

**Tech Stack:** Swift/Foundation/SwiftUI/XCTest, 기존 Rust/Tauri/serde, vanilla JS/Node, 기존 Playwright 검사. 해시는 macOS CryptoKit과 Rust에서 이미 lock에 있는 sha2 0.10.9를 사용한다.

**Spec:** [승인된 설계](../specs/2026-10-02-stock-forecast-evaluation-design.md), 설계 커밋 `6b40e1c`. 2026-10-02 사용자의 “진행”으로 설계 검토 단계가 승인됐고 이후 승인 범위의 Task1–6 구현·각 독립 검토를 완료했다.

**Status:** 개발 소스 1.25.0 / Mac66 / Windows r58의 Task1–7 구현·오프라인 검증·문서·CI와 각 독립 검토를 완료했다. 공개 코드 Grok 검토 뒤 F1–F6/M2를 수정했고, 추가 bootstrap 회귀 B1과 같은 초기 조회 경로를 보완하여 수정 범위 재검토를 통과했다. 결과는 `codex/stock-forecast-evaluation`의 로컬 커밋으로 보존한다. 선택적 실자료 probe는 안전한 비대화형 인증이 입증되지 않아 미수행이며 실제 모델 성능·Windows 실기·원격 CI·배포·설치를 주장하지 않는다. Swift 전체에서 발견한 두 테스트의 실패와 수정 후 관련 검사 결과는 [S19](../../wiki/sources.md#s19), 최종 보완·검토 근거와 Windows 중단 감지 한계는 [S20](../../wiki/sources.md#s20)에 구분해 기록했다.

## Global Constraints

- 목표는 같은 거래일 정규장 종가, 재현 cutoff는 종료 60분 전이다. 기본 최근 완료 60거래일, 선택지는 20/60/120, 관심 종목 최대 30개다.
- 재현 입력/목표 모두 adjusted=true. 실제 저장 기록의 adjusted=false 정산은 유지한다. 당시 수정 버전을 보장한다고 표현하지 않는다.
- 일봉 근거 61개/수익률 60개, 분봉 연속 수익률 최소 10개, 원자료 분봉 최대 1,400개, 페이지 최대 200봉/8페이지, 요청 사이 최소 250ms다.
- 재현 모델 이름은 설계의 `GBM daily zero drift v1 / replay v1`, `GBM 1m zero drift v1 / replay v1`, `GBM 10m zero drift v1 / replay v1` 그대로다. 기존 모델 이름·v1 이력을 재분류하지 않는다.
- 새 LLM·계좌 요청은 0건이다. 현재 macOS 수동 Codex 실행은 유지한다. Windows에 비동작 Codex 실행 버튼을 넣지 않는다.
- 기존 JSON/SQLite/CloseEstimates의 이동·초기화·삭제가 없다. 새 아카이브는 Forecasts/Backtests/<runUUID>/에만 쓴다. 원본 손상 시 보존하고 쓰기를 막는다.
- 임의 URL·파일 경로 IPC, 새 DB·Python 런타임·모델 플러그인·뉴스·자동 매매가 없다. 양 플랫폼의 이름·기본값·계산·한/영 설명을 맞춘다. 노치 표시 봉 최대 20개를 유지한다.
- 과거 자료 확보율과 누락을 결과에 표시한다. 데이터 없는 성공, 누락=오차 0, 다른 입력 집합의 모델 순위, 자동 모델 채택이 없다.
- 제품 구현 첫 커밋에 두 플랫폼 1.25.0, Mac build 66, Windows r58을 반영한다. 실행 시 버전이 이미 전진했다면 덮어쓰지 말고 그 버전보다 높인다. 문서만 작성하는 현재 단계는 1.24.1 유지다.
- 작업 시작 때 첨부 worktree/상태를 확인하고 적합한 것이 없으면 `codex/stock-forecast-evaluation`의 격리 작업 공간을 만든다. 미추적 연구·사용자 데이터·기존 실행 폴더는 건드리지 않는다.
- 모든 commit/push는 별도의 최신 @ponytail-review → 저장소 루트의 `node /Users/mac/.codex/hooks/ponytail-review-gate.js approve` → 정확히 한 Git 작업 순서다. Git 명령에는 실제 작업 공간의 `git -C`를 사용한다. 이 계획은 push·릴리즈 실행을 추가 승인하지 않는다.

## Review Focus

1. journal의 GBM과 Codex 대응 GBM이 동일 입력/출력으로 중복됨: 하나의 계산으로 채점하고 양쪽 출처를 보존한다. 충돌 출력은 비교에서 제외한다. Task 1.
2. 파일 저장 후 manifest 갱신 전에 종료됨: 기존 파일을 덮어쓰지 않고 해시를 확인하여 같은 실행의 진행 상태만 복원한다. Task 3.
3. 백그라운드 요청 도중 설정 창이 닫혔다 다시 열림: 새 실행·중복 요청 없이 상태와 취소 버튼을 복원한다. Task 4/6.
4. 공식 달력/일봉 날짜가 KR 통합 세션 목표와 맞지 않음: 날짜만 같다는 이유로 정산하지 않으며 검증 불가 이유를 표시한다. Task 4.
5. 따옴표·줄바꿈·CSV 수식이 들어간 종목명/설명: 화면에서 escape, CSV에서 기존 주입 방지를 유지하며 입력 원문은 변경하지 않는다. Task 6.

## Files and responsibilities

| 위치 | 역할 |
| --- | --- |
| 새 `Sources/Widgets/StockForecastEvaluation.swift` | 읽기 항목, 공통 점수, 선택 모델 대응 비교 |
| 새 `Sources/Widgets/StockBacktest.swift` | 공개 재현 타입, 순수 계산, 실행 저장/수집 상태; 다른 일반 저장 프레임워크로 분리하지 않음 |
| 새 `Sources/Settings/StockBacktestView.swift` | 과거 실행 제어와 결과; 기존 이력 화면은 통합 진입점을 재사용 |
| 새 `windows/penguinnotch/ui/backtests.js` | 기존 stocks.js 계산을 이용한 재현 타입·수집·UI; 별도 프런트 프레임워크 없음 |
| 새 `windows/penguinnotch/src/backtests.rs` | 공개 타입 검증과 제한된 파일 IPC; 토큰/인증을 소유하지 않음 |
| `Tests/Fixtures/stock-forecast-evaluation-v1.json` | 두 플랫폼이 읽는 공개 모의 입력/기대 출력; 개인 데이터 없음 |
| 새 `Tests/StockForecastEvaluationTests.swift`, `Tests/StockBacktestTests.swift`, `windows/scripts/test-backtests.cjs` | 각각 평가 규칙, 재현/저장/수집, Windows 동일 계약 |

추가 변경 위치는 각 Task에 적는다. 생성 Xcode 프로젝트·개인 이력·기존 미추적 연구는 커밋하지 않는다.

## Shared interfaces

- Swift `StockEvaluationRow`: `referenceID:String`, `source:StockEvaluationSource`, `inputKey:String?`, `stockID/currency/model/capture:String`, `sessionStart:Int64`, `inputPrice/previousClose/expectedClose:Decimal`, `lowerClose/upperClose:Decimal?`, `riseProbability:Double?`, `actualClose:Decimal?`. source는 recorded/pairedCalculation/replay이고, 원본 근거/응답은 별도 원본 참조로 읽는다. 기준선은 확률/구간을 갖지 않는다.
- Swift `StockEvaluationMetrics`: `total/evaluated/directionCount/directionHits:Int`, `mape/baselineMAPE/brier/coverage/meanWidthPercent:Double?`, `maeByCurrency:[String:Double]`. MAPE·coverage·width는 백분율 단위다. coverage만0..100이며 MAPE/width에는100 상한을 적용하지 않는다. probability/Brier는0..1이다. Windows도 같은 이름/단위의 객체를 반환한다.
- Swift `StockEvaluation.rows(journal:[StockForecastRecord], analyses:[StockCodexAnalysis]) -> [StockEvaluationRow]`; `metrics(_ rows:[StockEvaluationRow]) -> StockEvaluationMetrics`; `compare(_ rows:[StockEvaluationRow], selectedModels:Set<String>) -> StockEvaluationComparison`. Comparison은 `rows:[Row]`, `pairedCount:Int`, `excludedConflicts:Int`, `excludedMissingEvidence:Int`; Row는 `model:String`, `available/paired:StockEvaluationMetrics`다. JS는 `evaluationRows(records)`, `evaluationMetrics(rows)`, `evaluationComparison(rows, selectedModels)`로 같은 계약을 제공한다. 기존 Score의 반환 형식은 어댑터로 유지한다.
- 새 JSON 시간은 모두 안전한 정수 epoch ms다. `StockBacktestInput`은 version=1, caseID/stockID/market/currency/tradingDay, sessionStart/sessionEnd/cutoff, inputBarEnd/inputPrice/previousClose, priceBasis="provider-adjusted-as-fetched", dailyCloses[{date,price}], minutes[{end,open,high,low,close,volume}]를 갖는다. `StockBacktestCase`는 `{version:1,input,target:{actualClose,candleAt,fetchedAt},source:{provider:"toss",calendarFetchedAt,dailyFetchedAt,minutePages:[{before,nextBefore,fetchedAt}]}}`다. nextBefore는 null 또는 ISO8601 cursor이며 각 객체의 키를 화이트리스트로 고정한다.
- `StockBacktest.predict(input:StockBacktestInput, interval:StockChartInterval) -> StockBacktestOutcome`와 JS `predictReplay(input, interval)`은 target를 받지 않는다. outcome은 `{model,status:"forecast"|"skipped",reason:null|string,forecast:null|{expectedClose,lowerClose,upperClose,riseProbability,observations}}`다. 일봉 부족은 insufficient_daily_history, 분봉 부족은 insufficient_intraday_history다.
- `StockBacktestResult`는 `{version:1,caseID,inputSHA256,calculationVersion:"replay-v1",computedAt,outcomes}`다. inputSHA256은 저장한 case 파일 전체 바이트 해시이며, 평가 함수만 같은 해시의 case.target를 읽는다. 가격 유지는 inputPrice에서 파생하는 평가 기준선으로 두고 독립 모델 호출처럼 저장하지 않는다.
- `StockBacktestManifest`: version=1, runID(UUID), createdAt/collectionStartedAt/collectionCompletedAt?, protocolVersion="replay-v1", codeVersion, priceBasis, cutoffMinutes=60, sessions(20|60|120), symbols[], models[], status(ready|running|paused|completed), cases[{caseID,stockID,tradingDay,status:pending|saved|skipped,inputSHA256:null|string,resultSHA256:null|string,reason:null|string}]. 거래일 목록 확정 후 수집을 시작하고, UUID·고정 필드·완료 사례를 변경하지 않는다.
- caseID는 검증된 시장/심볼/거래일에서 만든 `us_AAPL_2026-09-25` 같은 값이다. `/`, `\\`, `..`, 임의 절대 경로를 허용하지 않는다. 가격·OHLC는 유한 양수, volume은 유한 비음수, OHLC 범위를 검증한다. 일봉 최대 61, minutes 최대 1,400, 종목 최대 30, 거래일 최대 120이다.
- Task 4의 `StockBacktestRequest`는 enum calendar(market:WatchedStock.Market,date:String) / candles(stock:WatchedStock,interval:String,before:String,count:Int,adjusted:Bool)다. interval은1m/1d, count는1..200, adjusted는true로 제한한다. `StockBacktestReply`는 calendar(value:MarketSessions,requestedAt:Int64) / candles(values:[StockCandle],nextBefore:String?,requestedAt:Int64)다. JS는 같은 tagged 객체를 사용한다. token은 request·reply·아카이브에 넣지 않는다.

## Verification commands

Swift 새 파일을 추가한 Task에서 `xcodegen generate` 후 고정 `Package.resolved`를 생성 프로젝트의 xcshareddata/swiftpm에 복사한다. `make clean`, `make verify-deps`, 개인 서명·키체인 탐색은 실행하지 않는다. 관련 Swift suite는 아래 명령의 only-testing을 바꿔 실행하며 같은 DerivedData를 쓰는 실행은 직렬화한다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PenguinNotch.xcodeproj -scheme PenguinNotch -destination 'platform=macOS' -configuration Debug -derivedDataPath build/forecast-evaluation-tests -only-testing:PenguinNotchTests/StockForecastEvaluationTests test CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
node --test windows/scripts/test-stocks.cjs windows/scripts/test-backtests.cjs
cargo test --locked --manifest-path windows/Cargo.toml --features tauri/macos-private-api backtests::tests::
```

성공 조건은 exit 0과 지정 suite의 실패 0이다. RED는 새 계약의 assertion 실패로 확인하며, 캐시·의존성 해결·미생성 파일 문제를 제품 버그의 근거로 사용하지 않는다.

---

### Task 1: 공통 읽기와 공정한 평가

**Files:** Create `Sources/Widgets/StockForecastEvaluation.swift`, `Tests/StockForecastEvaluationTests.swift`, `Tests/Fixtures/stock-forecast-evaluation-v1.json`. Modify `Sources/Widgets/StockForecastJournal.swift`, `windows/penguinnotch/ui/stocks.js`, `windows/scripts/test-stocks.cjs`.

**Interfaces:** Shared interfaces의 StockEvaluation rows/metrics/compare와 JS 대응 함수를 제공한다. 기존 Score/compareModels 호출의 반환값·단위는 유지하고 내부 계산만 공통 규칙에 연결한다.

- [x] **Step 1: RED 회귀를 추가한다.** Swift `testSelectedModelsIgnoreUnselectedPendingModel`: A/B의 동일 입력에 정산한 기록 각 1건과 C pending이 있을 때 `compare(rows, selectedModels:["A","B"]).pairedCount == 1`이다. `testEquivalentPairedGBMCountsOnce`는 recorded+pairedCalculation의 출력이 같으면 evaluated=1이고 양쪽 출처를 유지하며, 출력이 다르면 pairedCount=0이다. Node도 같은 fixture를 읽는다.
- [x] **Step 2: RED를 확인한다.** Verification commands의 Swift suite와 `node --test windows/scripts/test-stocks.cjs`를 실행하고 선택 모델·중복 처리의 assertion 또는 새 API 미구현으로 실패하는지 기록한다.
- [x] **Step 3: 최소 구현한다.** `StockEvaluation`과 JS 함수를 추가한다. MAPE=100*abs(expected-actual)/actual, Brier=(p-(actual>previous))², range는 양 끝 포함, width=100*(upper-lower)/input이다. 기존 isValid/validForecast를 통과한 기록만 읽는다. evidence=nil인 오래된 기록은 자체 점수·기준선까지만 허용하고 복수 모델 대응은 제외한다. recorded/paired가 완전히 같으면 출처만 묶고, 선택하지 않은 모델을 비교 필수 집합에 넣지 않는다.
- [x] **Step 4: GREEN과 경계를 확인한다.** 보합·p=.5, null 실적, 다른 통화, 실적/근거/capture 불일치, Codex abstain, 같은 이름의 다른 입력을 검사한다. MAPE>100을100으로 자르지 않고, 극단적인 유한 가격의 계산 오버플로우는 해당 지표 null/계산 불가로 표시해 성공0점으로 처리하지 않는다. MAPE/coverage는 백분율, Brier는 fraction, MAE는 통화별임을 양쪽에서 단언한다. fixture는 Swift #filePath 및 Node 저장소 상대 경로로 읽고 제품에 동봉하지 않는다.
- [x] **Step 5: 검토 후 로컬 commit한다.** 변경 파일만 stage하고 Global Constraints의 게이트를 통과한다. 첫 제품 commit에는 Task 7의 버전 값도 포함한다.

### Task 2: 봉별 과거 입력과 순수 계산

**Files:** Create `Sources/Widgets/StockBacktest.swift`, `Tests/StockBacktestTests.swift`, `windows/penguinnotch/ui/backtests.js`, `windows/scripts/test-backtests.cjs`. Modify `Sources/Widgets/StockForecast.swift`, `windows/penguinnotch/ui/stocks.js`, shared fixture.

**Interfaces:** StockBacktestInput/Case/Outcome/Result/Manifest와 predict/predictReplay를 제공한다. `StockForecast.intradayEstimate(price:Decimal,previous:Decimal,bars:[StockCandle],trading:TradingSession,at:Date,interval:StockChartInterval) -> StockForecast?`를 추가하고 기존 chartEstimate는 기존 시각으로 이를 호출한다. JS 대응은 `intradayEstimate(price,previous,bars,trading,at,interval)`이다.

- [x] **Step 1: RED `testTargetCannotChangePrediction`을 추가한다.** 같은 input에 actualClose=1과 1000을 붙인 두 case의 각 1m/10m/1d outcome이 같아야 한다. 원자료 응답에 cutoff 이후 극단적인 가격을 추가해도 완료 봉 필터를 통과한 input/예측은 같다. 검증할 input에 미래 봉을 직접 끼워 넣으면 거부한다. 일봉 61개 fixture에서 expectedClose===inputPrice, observations===60, cutoff===sessionEnd-3600000을 단언한다.
- [x] **Step 2: RED를 확인한다.** Swift only-testing을 StockBacktestTests로 바꾸고 `node --test windows/scripts/test-backtests.cjs`를 실행한다.
- [x] **Step 3: 타입과 최소 계산을 구현한다.** 검증한 case에서 input만 꺼낸다. 일봉 61개, 분봉 마지막 연속 완료 구간의 수익률 10개 이상을 사용한다. 남은 시간은 end-cutoff이며 일봉은 세션 길이, 분봉은 interval 길이로 나눈다. 기존 distribution과 완료 봉 집계를 재사용하고 live record의20..60 제한은 유지한다. JS module은 기존 `module.exports`/`globalThis.PenguinNotchBacktests` 패턴을 따른다.
- [x] **Step 4: GREEN과 시각을 확인한다.** DST·조기 종료, gap, volume=0, 11봉/10수익률, 60개 초과 분봉 수익률, 일봉60개 부족, cutoff-inputBarEnd>120000ms, NaN/Infinity/혼합 priceBasis, 잘못된 OHLC를 fixture와 작은 생성 열로 검사한다. 기존 StockForecastTests/StockChartTests도 한 번 실행한다.
- [x] **Step 5: 검토 후 로컬 commit한다.** 공개 모의 fixture만 포함하고 실제 사용자 자료는 넣지 않는다.

### Task 3: 보존 가능한 실행 저장과 Windows IPC

**Files:** Modify `Sources/Widgets/StockBacktest.swift`, `Tests/StockBacktestTests.swift`, `windows/penguinnotch/ui/backtests.js`, `windows/scripts/test-backtests.cjs`, `windows/penguinnotch/src/main.rs`, `windows/penguinnotch/Cargo.toml`, `windows/Cargo.lock`. Create `windows/penguinnotch/src/backtests.rs`.

**Interfaces:** Swift `StockBacktestArchive(directory:URL)`는 `list() throws->[StockBacktestManifest]`, `create(_ manifest:StockBacktestManifest) throws`, `loadManifest(runID:UUID) throws->StockBacktestManifest`, `saveCase(runID:UUID,body:Data) throws->String`, `loadCase(runID:UUID,caseID:String) throws->(body:Data,sha256:String)`, `saveResult(runID:UUID,body:Data) throws->String`, `loadResult(runID:UUID,caseID:String) throws->Data?`, `updateProgress(runID:UUID,entries:[StockBacktestManifest.Entry],status:StockBacktestManifest.Status) throws`를 제공한다. Entry/Status는 Shared interfaces의 cases 원소/status enum이다. Rust/Tauri는 단일 `stock_backtest_archive(request:ArchiveRequest) -> Result<ArchiveReply,String>`이며 같은 list/create/loadManifest/saveCase/loadCase/saveResult/loadResult/updateProgress tagged enum이다. create는 manifest, save는 runID+UTF-8 body, load는 runID+caseID, update는 runID+entries+status만 받는다. Reply는 manifests/manifest/body+sha256/receipt(sha256)/empty이며 action과 대응해야 한다. 경로는 native에서 계산하고 JS `archive(action,payload)`는 이 command만 호출한다.

- [x] **Step 1: RED 저장 회귀를 추가한다.** `testCrashAfterCaseSaveResumesWithoutOverwrite`는 saveCase 이후 manifest 갱신 전에 중단하고, 다시 읽은 같은 hash를 연결하여 원본 byte를 유지한다. `testUnknownNestedFieldsAndTraversalRejectWithoutWriting`는 accountSeq/token/quantity, ../, 잘못된 runID, 미지원 version/모델을 모든 계층에서 거부한다.
- [x] **Step 2: RED를 확인한다.** Swift StockBacktestTests, Node test-backtests, Rust `backtests::tests::`를 실행한다. 의존성 해결 단계에서 중단되면 제품 테스트 미실행으로 구분한다.
- [x] **Step 3: 원자 저장을 구현한다.** SHA-256은 CryptoKit과 현재 lock의 sha2 `=0.10.9`를 사용한다. 직접 의존성을 선언해 package graph만 갱신하고 다른 crate는 갱신하지 않는다. case/result는 typed whitelist로 검증한 UTF-8 body byte를 그대로 저장·해시하며 다시 직렬화하지 않는다. 파일당2MiB, 새 파일은 임시 작성 후 같은 폴더에서 원자 배치, 기존 같은 값은 no-op, 다른 값은 저장 거부다. manifest의 고정 항목·완료 entry는 유지하고 mutable progress만 원자 갱신한다.
- [x] **Step 4: GREEN과 실패 보존을 확인한다.** 같은 case의 동시 save, 쓰기/rename 실패, 결과의 input hash 불일치, 미지원/손상 JSON, manifest 중단, symlink 외부 경로 이탈에서 원본이 그대로인지 검사한다. 공통 fixture body hash가 양쪽 native에서 같고 기존 GBM/Codex/SQLite에는 쓰지 않음을 임시 폴더에서 단언한다.
- [x] **Step 5: 검토 후 로컬 commit한다.** Cargo.lock 차이는 직접 의존성 추가분만 확인한다.

### Task 4: 제한된 토스 과거 자료 수집과 재개

**Files:** Modify `Sources/Widgets/StockBacktest.swift`, `Sources/Widgets/TossInvestClient.swift`, `Tests/StockBacktestTests.swift`, `windows/penguinnotch/ui/backtests.js`, `windows/scripts/test-backtests.cjs`. 필요한 request cancellation 확인은 `windows/penguinnotch/src/stocks.rs`의 기존 tests에 한정한다.

**Interfaces:** Swift `@MainActor StockBacktestStore:ObservableObject`는 published `runs,activeRunID,progress,errorMessage`, `start(symbols:[WatchedStock],sessions:Int) async throws`, `resume(runID:UUID) async throws`, `cancel()`을 제공한다. request adapter `(StockBacktestRequest) async throws -> StockBacktestReply`, 시계·대기를 init에 주입한다. Request는 calendar(market,date)/candles(stock,interval,before,count,adjusted)만 허용한다. JS `BacktestStore({invoke,stockRequest,now,sleep})`도 같은 state/start/resume/cancel을 제공한다.

- [x] **Step 1: RED 수집 회귀를 추가한다.** `testCollectorsUseOnlyFrozenPublicInputs`는 완료60거래일, cutoff 이전 분봉·adjusted=true·200/page, 반복 nextBefore가 있는 fixture를 반환한다. accounts/holdings/prices/model calls=0, 최대8페이지/1400행, 페이지 간>=250ms를 단언한다. `testSessionMismatchIsSkipped`는 KR calendar와 목표 candle의 불일치에서 결과 없음/이유 있음을 확인한다.
- [x] **Step 2: RED를 확인한다.** Swift/Node Backtest suite를 실행한다. URLProtocol과 fake IPC의 공개 모의 응답만 사용한다.
- [x] **Step 3: 순차 수집을 구현한다.** 달력을 시장/날짜별로 공유하고 previousBusinessDay를 따라 고정 날짜 목록을 먼저 확정한다. 대상 날짜의 cutoff 분봉과 sessionEnd 이전 일봉을 count=200으로 읽는다. Swift는 `TossInvestAPI.backtestPage(token:String,stock:WatchedStock,interval:String,before:String,session:URLSession) async throws->StockBacktestReply`를 추가해 candleData를 재사용하며 calendar는 기존 marketSessions의 at을 현지 날짜에 맞춘다. 생산용 Store는 start/resume 때만 기존 TossCredentials/TossInvestAPI.accessToken을 사용하며 별도 토큰 캐시는 만들지 않는다. Windows는 기존 stock_request의 calendar(date)와 candles(interval:"1m",count:200,before,adjusted:true)를 한 페이지씩 호출한다. 8페이지 동안 native lock을 잡는 기존10m command는 사용하지 않는다.
- [x] **Step 4: GREEN과 재개를 확인한다.** inclusive 경계의 같은 값 중복은 제거하고 다른 값은 skipped, 반복 cursor도 skipped, 부분 제공은 모델별 보류다. 401/429는 기존 상한을 지키며 인증 실패는 paused다. 설정/credential generation 변경은 후속 요청을 멈추고 cancel 이후 늦은 응답은 저장하지 않는다. macOS의 provider/키 저장·삭제 경로는 공유 Store.cancel을 호출하고 페이지 완료 전 stockSettingsRevision도 확인한다. 이중 start는 거부하고 창을 닫았다 열어도 같은 Store를 유지한다. 사용자 resume 전에는 자동 재개하지 않는다. 저장한 case는 재조회0건으로 재사용하고 사례마다 progress를 갱신한다.
- [x] **Step 5: 검토 후 로컬 commit한다.** 개인 인증이 필요한 자동 테스트나 서비스 업로드는 추가하지 않는다.

### Task 5: 재현 결과의 대응 평가와 CSV

**Files:** Modify `Sources/Widgets/StockForecastEvaluation.swift`, `Sources/Widgets/StockBacktest.swift`, `Tests/StockForecastEvaluationTests.swift`, `Tests/StockBacktestTests.swift`, `windows/penguinnotch/ui/backtests.js`, `windows/scripts/test-backtests.cjs`.

**Interfaces:** Swift `StockEvaluation.replayRows(runID:UUID,caseData:StockBacktestCase,result:StockBacktestResult,inputSHA256:String) throws->[StockEvaluationRow]`, JS `replayRows(runID,caseData,result,inputSHA256)`를 제공한다. `StockEvaluation.csv(rows:[StockEvaluationRow],metrics:StockEvaluationMetrics,details:[String:String]) -> String`/JS `evaluationCSV(rows,metrics,details)`은 원본 입력 참조, source/가격 기준/분모/제외 이유/모델 결과를 내보낸다. details는 referenceID별 검증한 원본 공개 입력·응답 JSON이다. 기존 StockForecastJournal.csv와 Windows csv도 유지한다. replay의 inputKey는 runID/caseID/inputSHA256 참조다.

- [x] **Step 1: RED `testIncompleteCohortNeverScoresAsZero`를 추가한다.** 두 case에서 A 성공2건/B 성공1건+skipped1건이면 A evaluated=2/B=1, 선택A+B pairedCount=1이다. pending·다른 actual·다른 hash는 paired=0이다. baseline에 p/range를 만들지 않고 각 GBM MAPE=baseline임을 단언한다.
- [x] **Step 2: RED를 확인한다.** Swift Evaluation/Backtest와 Node 두 suite를 실행한다.
- [x] **Step 3: 기존 평가 함수에 연결한다.** replayRows를 Task 1의 metrics/compare에 전달한다. actual은 case.target에서만 읽는다. 시장·종목·거래일 filter와 확보/성공/보류/대응/일수를 계산한다. calibration은 기존10pp/Wilson95식을 적용하며 수동/자동/replay, 통화별 MAE를 분리한다. recorded와 pairedCalculation은 같은 원본 입력끼리 비교할 수 있지만 replay와 혼합하지 않는다. 보류 사례는 manifest/outcome 건수로 표시하고 가짜 성공 row를 만들지 않는다.
- [x] **Step 4: GREEN과 CSV를 확인한다.** target 변경 시 예측 불변/점수만 변화, 미지원/다른 버전 결과 거부, 보합·p=.5·구간 양 끝·선택 모델 변경에 따른 분모를 확인한다. CSV roundtrip에서 가격/시각/source/reason/입력 참조·근거를 유지하고 원본 파일을 바꾸지 않는다. 가격 상대 오차<=1e-8, 확률/집계 차이<=1e-6으로 공통 fixture 결과를 대조한다.
- [x] **Step 5: 검토 후 로컬 commit한다.** TEST를 보고 변동성·임계값을 다시 선택하거나 LLM을 재실행하지 않는다.

### Task 6: 기록 UX 통합과 실행 화면

**Files:** Create `Sources/Settings/StockBacktestView.swift`. Modify `Sources/Settings/StockSettings.swift`, `Sources/Settings/StockForecastHistoryView.swift`, `Sources/Settings/StockCodexAnalysisView.swift`, `Sources/Localizable.xcstrings`, `windows/penguinnotch/ui/{settings.html,stocks.js,stocks.css,backtests.js}`, `Tests/StockForecastEvaluationTests.swift`, `windows/scripts/test-{backtests,settings-browser,ko-i18n}.cjs`.

**Interfaces:** `StockForecastHistoryView(journal:StockForecastJournal, analyses:StockCodexAnalysisStore, backtests:StockBacktestStore)`를 통합 진입점으로 삼는다. 기존 `StockCodexHistoryView`는 같은 화면에 Codex 초기 filter를 전달한다. `StockBacktestView(store:StockBacktestStore)`는 시작/취소/재개와 결과를 표시한다. JS `mountBacktests(element,store,language)`는 render/show를 반환하고 stocks.mountSettings 기록 탭에서 호출한다. 창/뷰 재생성 때 Store를 다시 만들지 않는다.

- [x] **Step 1: RED UX 회귀를 추가한다.** Swift render tests는 단일 기록 진입점, GBM+Codex 양쪽 출처, 요약/접힌 상세를 확인한다. Windows 실제 페이지 fixture에서 키보드 전환/20·60·120 선택, 시작→닫기→다시 표시에도 start=1이고 취소 가능함을 단언한다. 이름 `=TEST,"quoted"\nnext`의 escape와 CSV 주입 방지도 확인한다.
- [x] **Step 2: RED를 확인한다.** Swift Evaluation suite, Node test-backtests, 설치된 Playwright로 `node windows/scripts/test-settings-browser.cjs`를 실행한다. 외부 통신은 fixture에서 abort한다.
- [x] **Step 3: 화면을 연결한다.** 진입점은「예측 기록과 평가 / Forecast history and evaluation」, 내부는「실제 저장 기록 / Saved predictions」「과거 재현 / Historical replay」다. 초기 요약은 평가 건수·기준선과의 차이·Brier이고 나머지는 상세에 둔다. 제한 문구는「현재 조회 자료로 재구성; 당시 정보만 사용한 검증을 보장하지 않음 / Reconstructed from data fetched now; availability at the original time is not guaranteed.」이다. GBM 기대값=입력 가격과 macOS 전용 Codex 실행을 표시하며 비동작 조작은 만들지 않는다.
- [x] **Step 4: GREEN과 회귀를 확인한다.** en/ko 문구, 680x520 창/큰 호버 글씨, 열린 상세/filter/CSV 유지, Finnhub 미지원, 빈/손상 이력, 전체 skipped, 부분 완료를 검사한다. 기존 check-ui-scripts/test-stocks/test-widgets/test-ko-i18n/test-claude-auth-ui 및 settings/notch browser suite를 한 번 실행하고 외부 호출/비밀 로그0을 확인한다.
- [x] **Step 5: 검토 후 로컬 commit한다.** 이미지/로그는 공개 모의 응답만 CI artifact에 저장하고 개인 기록은 촬영하지 않는다.

### Task 7: 양 플랫폼 검증과 결과 전달

**Files:** Modify `.github/workflows/windows.yml`, `project.yml`, `windows/penguinnotch/{Cargo.toml,tauri.conf.json,src/main.rs}`, `windows/Cargo.lock`, `README.md`, `README.ko.md`, `windows/README.md`, `docs/wiki/{index,stocks,sources,log}.md`. 생성 Info.plist는 project.yml의 같은 설정을 반영한 차이만 포함한다.

**Interfaces:** CI는 Node backtests와 공통 fixture 변경을 감지해 Windows native 검사를 실행한다. 로컬 보고서는 manifest/결과 hash·요청/유효/누락·모델별 metrics를 참조하고 공개 위키에는 계약과 공개 fixture 검증만 기록한다.

- [x] **Step 1: 버전/CI 검사를 준비한다.** 첫 제품 commit에1.25.0/Mac66/r58을 설정하고 기존 package 해결을 유지한다. Windows workflow에 `Tests/Fixtures/stock-forecast-evaluation-v1.json` path와 `node --test scripts/test-backtests.cjs`를 추가한다. fixture만 바뀌어도 Windows 검사가 실행되고 양 플랫폼 version이 같음을 단언한다.
- [x] **Step 2: 관련 회귀가 GREEN인지 확인한다.** Swift Evaluation/Backtest/Forecast/Chart/Journal/CodexAnalysis/Quote/Timing, Windows Node UI/stock/backtest, Rust 전체 tests를 실행한다. 공유 계산·저장을 변경하므로 마지막에 Swift 전체 suite를 한 번 실행한다. Mac Rust는 `--features tauri/macos-private-api`, Windows CI는 `cargo test --locked`를 사용한다. 캐시 정리로 무관한 연구를 건드리지 않는다.
- [ ] **Step 3: 실제 제공 자료를 별도 근거로 확인한다.** 기존 앱의 비대화형 인증으로 공개 시장 데이터를 평가한다면 먼저 선택1종목/20거래일을 제한 실행한다. 키체인 승인이 필요하면 중단하고 비밀을 출력하지 않는다. 제공 범위가 부족해도 누락을 저장하고 시작/확보/누락/모델 건수·hash를 ignored `build/`의 로컬 보고서에 기록한다. 자료를 확보하지 못했다면 모의 검증과 구분해 명시한다.
- [x] **Step 4: 전체 독립 검토와 문서를 완료한다.** Grok 읽기 전용으로 추적된 공개 변경만 보내 동일 시점 입력/가격 기준/저장/취소를 교차 검토한다. 개인 아카이브·인증·원자료·TEST 라벨·미추적 연구는 보내지 않는다. 부모가 근거를 확인하여 필요한 수정과 영향받은 검사만 수행한다. 양 언어 README와 위키에 구현/검증/미검증을 구분한다.
- [x] **Step 5: 최종 로컬 commit과 전달을 완료한다.** 최신 Ponytail review/게이트 후 코드/공개 fixture/문서만 commit한다. 변경, 테스트, 사용법, 과거 분봉 확보 한계, Windows 실기 미검증을 보고한다. 이 작업의 완료만으로 GitHub push/정식 release/설치를 실행하지 않는다.

## Self-review and execution handoff

각 설계 절은 Task1(저장 기록/비교), Task2(입력/계산), Task3(저장), Task4(수집/취소), Task5(지표), Task6(UI), Task7(검증/문서)에 대응한다. Review Focus의5건은 각 Task에 구체적인 검사를 배정했다. 기존 API의 capture/시각/원본 byte와 새 epoch-ms 공개 아카이브를 혼동하지 않는다.

추천은 **Native 실행 + 마지막 Grok 독립 검토**다. 공유 타입과 fixture 의존성이 강하므로 이 세션에서 순서대로 구현하고 빌드를 직렬화하면 충돌을 줄일 수 있다. Subagent-driven을 선택하면 같은 계약을 유지하면서 내장 하위 에이전트가 Task를 담당하고 Grok은 공개 코드의 읽기 전용 검토를 맡는다. 어느 방법이든 이 작성된 계획의 검토와 실행 방법 선택 후 제품 구현을 시작한다.
