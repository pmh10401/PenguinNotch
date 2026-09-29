# 출처 목록

등록일: 2026-09-28. 기존 항목을 새 버전으로 덮어쓰지 않고 이후 검증에는 새 항목을 추가합니다. 요약은 주제 페이지에서 갱신합니다. Git에 고정된 코드와 문서를 원자료로 재사용하므로 별도의 전체 복사본은 만들지 않습니다.

## S1

- 자료: Andrej Karpathy, [LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f).
- 확인: 2026-09-28 08:46 UTC, 원문의 Markdown 11,985바이트.
- SHA-256: `dc3efe98ae62f23dd08acad13aba2e95287beb20b6bec2f4af0423557fe37401`.
- 용도: 원자료 보존, 서로 연결된 요약, 색인·변경 이력·점검 절차라는 운영 방식을 참고했습니다. 현재 URL의 내용은 이후 바뀔 수 있으며 이 해시는 확인 시점의 원문을 식별합니다. 원문 전체를 저장소에 재배포하지 않습니다.

## S2

- 기준 커밋: `b7b1b69d29944f76f7431933d5d78a41c135f81f`.
- [영문 README](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/README.md), [한국어 README](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/README.ko.md), [Windows README](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/windows/README.md).
- 용도: 사용자 기능, 현재 플랫폼 지원 범위와 설정 위치. 구현과 충돌하면 코드와 실행 증거를 함께 확인합니다.

## S3

- 기준 커밋: S2와 동일.
- [macOS 노치 컨트롤러](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/Sources/Notch/NotchWindowController.swift), [노치 모델](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/Sources/Notch/NotchViewModel.swift), [Windows 노치](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/windows/penguinnotch/ui/notch.html).
- [macOS 스크롤 테스트](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/Tests/NotchScrollTests.swift), [Windows 브라우저 스크롤 검사](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/windows/scripts/test-notch-scroll-browser.cjs).

## S4

- 기준 커밋: S2와 동일.
- [macOS 시세](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/Sources/Widgets/StockQuote.swift), [차트](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/Sources/Widgets/StockChart.swift), [Windows 주식 UI·계산](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/windows/penguinnotch/ui/stocks.js), [Windows 주식 백엔드](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/windows/penguinnotch/src/stocks.rs).
- 용도: 앱이 구현한 세션·시세·캐시·이력 계약. 외부 API의 현재 계약을 보증하는 문서는 아닙니다.

## S5

- 기준 커밋: S2와 동일.
- [GBM 계산](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/Sources/Widgets/StockForecast.swift), [Codex 입력·출력·보관](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/Sources/Widgets/StockCodexAnalysis.swift), [Codex 실행](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/Sources/Widgets/StockCodexRunner.swift).
- 용도: 실제 앱의 예측 모델과 입력 제한. 별도로 진행한 연구 평가가 앱에 채택되었다는 근거로 사용하지 않습니다.

## S6

- [정식 릴리즈 v1.20.4](https://github.com/pmh10401/PenguinNotch/releases/tag/v1.20.4), 소스 `e8cea6114ad5beb11b237e970a26c0f64b2ac51c`.
- [macOS 테스트](https://github.com/pmh10401/PenguinNotch/actions/runs/36390721157), [macOS 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/36390721041), [Windows 테스트](https://github.com/pmh10401/PenguinNotch/actions/runs/36390721057), [최종 Windows 패키지·설치 검사](https://github.com/pmh10401/PenguinNotch/actions/runs/36392130238).
- [파일 해시](https://github.com/pmh10401/PenguinNotch/releases/download/v1.20.4/SHA256SUMS.txt). 릴리즈 자산은 교체될 수 있으므로 이 파일의 2026-09-28 확인 해시도 기록합니다: `4a8dc51a9e0f0dac74a891773f5f375941a544f965917dfa7540d1db10fbf266`.
- 이 검증 결과는 해당 릴리즈의 증거이며, 이후 코드의 테스트 통과를 대신하지 않습니다.

## S7

- 기준 커밋: S2와 동일.
- [Claude 인증 읽기](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/Sources/Providers/ClaudeCredentials.swift), [Antigravity 인증 읽기](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/Sources/Providers/AntigravityCredentials.swift), [기여 문서](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/CONTRIBUTING.md), [릴리즈 노트](https://github.com/pmh10401/PenguinNotch/blob/b7b1b69d29944f76f7431933d5d78a41c135f81f/Sources/Settings/ReleaseNotes.swift).
- 용도: 백그라운드 키체인 읽기와 과거 기여 문서 사이의 불일치 확인.

## S8

- 확인: 2026-09-28 UTC (한국 시각 2026-09-29). 기준 커밋 `5453e76207717135562039cb2b41b617895fb569` 이후의 1.20.5 작업 트리이며 아직 게시되지 않았습니다. S2의 배포 기준을 대체하지 않습니다.
- [Windows 설정 구현](../../windows/penguinnotch/ui/settings.html)의 SHA-256: `497ec253022fbfe3037a296aa98d9b9c9c7db17240c4b5b6de0c346290d00de4`.
- [브라우저 회귀 검사](../../windows/scripts/test-settings-browser.cjs)의 SHA-256: `d7fafb221ee11e4b5e7b6bc554eba90222840b6dde98b8200f990716824a6831`.
- macOS 분류의 근거: [설정 섹션](../../Sources/Settings/SettingsView.swift), [모니터링·생활 위젯 페이지](../../Sources/Settings/WidgetSettingsPanes.swift).
- Playwright Chromium에서 실제 HTML을 실행하고 네이티브 호출은 가짜 공개 데이터로 대체했습니다. 24개 배치와 설정 저장·복원·실패 경로 검사가 통과했습니다. 별도의 Browser 플러그인/스킬이 없어 설치된 Playwright를 사용했습니다. 계좌·인증 파일·실제 API에는 접근하지 않았습니다. 실제 Windows WebView2 검증은 아닙니다.
- 추가 검사: `check-ui-scripts.mjs`, `test-stocks.cjs`, `test-widgets.cjs`, `test-claude-auth-ui.cjs`, `test-ko-i18n.cjs` 모두 종료 코드 0. 버전 메타데이터와 번역 JSON, 변경 공백 검사를 통과했습니다.

## S9

- 확인: 2026-09-29 KST. CodeNotch 원본 [00833690311067354c77951fcaaf6ffca774916e](https://github.com/vinzdg/codenotch/commit/00833690311067354c77951fcaaf6ffca774916e)(1.19.0)을 PenguinNotch `dd3f301d4bbf02962518ab51ce5c24b50618124d`의 설정 개편 위에 병합했습니다. 공통 기준은 `aae2c1f77bd2f2fb6c03aa58ca6329c5d003fab4`, 원본의 추가 커밋은 134개입니다.
- 소스 버전: 1.21.0, macOS build 58, Windows r50. 정식 설치 파일 배포·설치와 구분합니다.
- 통합 계약: [노치 모델](../../Sources/Notch/NotchViewModel.swift), [노치 컨트롤러](../../Sources/Notch/NotchWindowController.swift), [업데이터](../../Sources/App/Updater.swift), [Windows 설정](../../windows/penguinnotch/ui/settings.html). PenguinNotch의 업데이트 피드·기존 자격 증명 이동 규칙을 유지하며, 원본의 `site/Codenotch.dmg`와 앱캐스트를 게시하지 않습니다.
- macOS 검증: 서명을 끈 ARM64 Debug 전체 Xcode 테스트 **2,186개, 건너뜀 11개, 실패 0**, 종료 코드 0. 건너뛴 항목은 선택적으로 실행하는 실제 서비스·모델 검사 8개와 실제 노치 디스플레이가 필요한 검사 3개입니다. 마지막 이동·늘어남·클리핑 수정까지 포함하며, 합성 화면과 이벤트로 스크롤·배치·드래그를 검사했습니다. 로컬 로그는 `/tmp/penguin-upstream-final-full.log`입니다.
- Windows 검증: Mac 호스트 Rust 테스트 **184개 통과, 4개 제외**, GNU Windows 전체 대상 교차 컴파일, Node **19개 통과**, HTML 3개 문법 검사 모두 종료 코드 0. Playwright에서 가짜 네이티브 응답으로 설정 **24개**, 노치 **48개** 배치 및 저장·호버·드래그·휠·실시간 모양 변경을 검사했습니다. 실제 Windows 실행 결과와 구분합니다.
- 검토 중 보완: Apify의 백그라운드 키체인 읽기는 기존 비대화형 규칙과 명시적인 접근 허용을 재사용합니다. 완료된 Codex 하위 작업이 완료 알림을 막던 조건과 사용자 지정 JSON 토큰 합계의 정수 변환 오류도 회귀 검사로 확인했습니다.
- 검증 소스 SHA-256: `Sources/Notch/NotchViewModel.swift` = `aace35324c74d2555d93a986a74b3ddd2336d92a92e1b050dce185c7d5341c6b`, `Sources/Notch/NotchWindowController.swift` = `416a9f4ba8d331244fa86480c9ca7ae0db06b87e7835af0ab194dd3916eb38e9`, `windows/penguinnotch/ui/settings.html` = `36339fa826d70e8eefdece2c269ce191e8355f05c90acc1b1bc408eb97b5c46e`.
- 한계: 실제 Windows/WebView2의 다중 모니터·배경 캡처·최상위 창 동작, 실제 계정·시세 API, 업데이트 다운로드·설치는 이 병합에서 실행하지 않았습니다. 연구 평가 자료와 설치본은 변경하지 않았습니다.

다음 명령은 저장소 루트에서 macOS 검증을 재현합니다. Windows 브라우저 검사는 설치된 Playwright가 필요하며, 별도의 네이티브 Windows 확인을 대신하지 않습니다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test-ci
node --test windows/test-codex-headline.cjs windows/test-light-surface.cjs windows/scripts/test-ko-i18n.cjs windows/scripts/test-stocks.cjs windows/scripts/test-claude-auth-ui.cjs windows/scripts/test-widgets.cjs
node windows/scripts/check-ui-scripts.mjs
node windows/scripts/test-settings-browser.cjs
node windows/scripts/test-notch-scroll-browser.cjs
```

## S10

- 확인: 2026-09-29 KST. 원본 통합 커밋 [34d30cb8122a93b5a432f93b910c50f94cfaca20](https://github.com/pmh10401/PenguinNotch/commit/34d30cb8122a93b5a432f93b910c50f94cfaca20)과 그 이후 1.21.1(macOS build 59, Windows r51)의 드래그 보완입니다.
- 확정한 회귀: [NotchPanel](../../Sources/Notch/NotchPanel.swift)의 `mouseUp` 처리에서 최종 이동 거리를 확인하지 않았습니다. [NotchScrollTests](../../Tests/NotchScrollTests.swift)의 새 합성 입력은 중간 이동 이벤트 없이 0·4·5·30포인트를 움직여 놓습니다. 기존 구현은 5·30포인트 검사에서 실패했고 수정 후 통과했습니다. [NotchWidgetsTests](../../Tests/NotchWidgetsTests.swift)는 실제 드롭 호출·좌표·숨김 항목 보존까지 확인합니다. 소스 `NotchPanel.swift`의 SHA-256은 `9e3df393aff7241fa3464447fe9793b43d704f8a92be1ea88ca838d077e5e986`입니다.
- 원본 통합의 GitHub 결과: [macOS CI](https://github.com/pmh10401/PenguinNotch/actions/runs/36501163327)의 두 시도 모두 `testDraggingNotchItemSavesOrderAndKeepsHiddenSlot`에서 순서가 바뀌지 않는 실패가 있었습니다. 로컬의 같은 검사 15회는 모두 통과했습니다. Grok의 읽기 전용 교차 검토도 최종 거리 판정의 타당성과 CI 원인 미확인을 구분했습니다. 이벤트 병합이나 좌표 변환을 확인된 원인으로 단정하지 않습니다.
- 같은 통합 커밋의 [Windows 테스트](https://github.com/pmh10401/PenguinNotch/actions/runs/36501163310)는 네이티브 Rust 188개 통과·4개 제외, [Windows 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/36501163351)는 NSIS 설치·doctor·제거·업데이트 피드 생성에 성공했습니다. [macOS 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/36501163299)도 성공했습니다. 패키지 성공은 macOS CI 실패를 대신하지 않으며, 정식 버전 태그 배포나 사용자 설치본 변경과도 구분합니다.
- 후속 수정의 집중 검사: 드래그·스크롤 18개 중 건너뜀 1개·실패 0, 별도 Ollama 셀 클릭 검사 1개 통과. 실제 사용자 계정·키체인 읽기·설치·주식 시세 API는 사용하지 않았습니다.
- 1.21.1 최종 로컬 검사: 서명을 끈 ARM64 Debug 전체 Xcode 테스트 **2,187개, 건너뜀 11개, 실패 0**, 종료 코드 0. 로그 `/tmp/penguin-upstream-1.21.1-full.log`. 기존 CI 실패 검사와 새 놓기 처리 회귀를 모두 포함합니다. 이 결과는 후속 GitHub CI의 성공을 미리 보장하지 않습니다.

## S11

- 확인: 2026-09-29 KST. [2ae6eb182f6156620f05764cfcaca67132ca5dce](https://github.com/pmh10401/PenguinNotch/commit/2ae6eb182f6156620f05764cfcaca67132ca5dce)의 [macOS CI](https://github.com/pmh10401/PenguinNotch/actions/runs/36503733901)는 합성 이벤트의 좌표 불일치를 직접 기록했습니다. `testReleaseCompletesDragWithoutAnIntermediateEvent`에서 기대 `(100, 100)`과 실제 `(100, -468)`, 작은 목록 드래그에서 기대 `(383.025641, 418.406838)`와 실제 `(989.025641, 340.406838)`가 달랐습니다. 드롭 자체는 호출됐지만 잘못된 좌표가 항목 영역 밖이어서 순서가 유지됐습니다.
- Apple의 [mouseEvent 문서](https://developer.apple.com/documentation/appkit/nsevent/mouseevent(with:location:modifierflags:timestamp:windownumber:context:eventnumber:clickcount:pressure:))는 입력 위치를 창의 기본 좌표로 정의합니다. 위 오류는 로컬 macOS 27의 큐에서는 재현되지 않았으며, 테스트가 공급한 창 내부 좌표와 CI macOS 26에서 큐가 돌려준 좌표의 불일치입니다. 일반 사용자 마우스 이벤트의 좌표 오류라고 단정하지 않습니다.
- 후속 소스: 1.21.2(macOS build 60, Windows r52). [NotchPanel](../../Sources/Notch/NotchPanel.swift)의 선택적 `nextCellDragEvent`가 없으면 기존 `nextEvent`를 호출합니다. [위젯](../../Tests/NotchWidgetsTests.swift)·[스크롤](../../Tests/NotchScrollTests.swift)·[Ollama 셀](../../Tests/OllamaTests.swift) 검사에서만 유한 이벤트 목록을 공급합니다. 실제 클릭·히트 테스트·드롭·순서 저장·숨김 항목·5포인트 경계 단언은 유지합니다. `NotchPanel.swift` SHA-256: `ddb4025685acb65ba0e4145af6b3e1beb49e8b7dcf35b6630e66cfa2de82a350`.
- 집중 검사: 26개, 건너뜀 1개, 실패 0, 종료 코드 0. 로그 `/tmp/penguin-local-event-fixtures.log`. Grok의 읽기 전용 검토는 이벤트 수명·종료 처리와 기존 단언 보존을 확인했습니다. 실제 AppKit 큐를 흉내 낸 좌표 보정은 적용하지 않았습니다.
- 최종 로컬 전체 검사: **2,187개, 건너뜀 8개, 실패 0**, 종료 코드 0. 로그 `/tmp/penguin-upstream-1.21.2-full.log`. macOS 26 GitHub CI 통과 여부는 이 로컬 macOS 27 결과와 구분합니다.
- 후속 원격 검증: [3fe7ab56c1c6ca02bfe7b3ae207d97a1bd701dce](https://github.com/pmh10401/PenguinNotch/commit/3fe7ab56c1c6ca02bfe7b3ae207d97a1bd701dce)의 [macOS 26 CI](https://github.com/pmh10401/PenguinNotch/actions/runs/36505085638)가 **2,187개, 건너뜀 13개, 실패 0**으로 통과했습니다. 앞서 실패한 놓기·스크롤 후 클릭/드래그·작은 목록 재정렬·Ollama 셀 클릭 네 검사가 모두 통과했고 SwiftPM 의존성 검사도 성공했습니다. [Windows CI](https://github.com/pmh10401/PenguinNotch/actions/runs/36505085653)는 **188개 통과, 4개 제외, 실패 0**, [Windows 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/36505085668)는 설치·doctor·제거·업데이트 피드 생성에 성공했습니다. 최종 소스의 원격 성공은 앞선 실패 기록을 대체 삭제하지 않고 여기에 추가합니다.
- 같은 코드의 [macOS 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/36505085624)도 DMG 생성·아티팩트 업로드·기존 `preview` 게시에 성공했습니다. 네 가지 GitHub 작업이 모두 성공했습니다. 정식 `v1.21.2` 릴리즈나 사용자 Mac 설치는 수행하지 않았습니다.

## S12

- 확인: 2026-09-29 KST. 기준 `e221fe5db30a24693240b407c9e9ef8acfe697ce` 이후 1.22.0 소스(macOS build 61, Windows r53). Grok 4.6 high가 격리된 작업 트리에서 구현하고 Codex가 통합·검증했습니다. 실제 계정·자격 증명·연구 원본은 사용하지 않았습니다.
- 구현: [Windows 설정](../../windows/penguinnotch/ui/settings.html), [노치](../../windows/penguinnotch/ui/notch.html), [사용량](../../windows/penguinnotch/src/usage.rs), [업데이터](../../windows/penguinnotch/src/updater.rs), [날씨 수집](../../windows/penguinnotch/src/system_usage.rs), [위젯 표시](../../windows/penguinnotch/ui/widgets.js). 두 언어 README와 [공통 동작·차이](project.md#1220-공통-조작과-남은-차이)를 함께 갱신했습니다.
- macOS 전체: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test-ci`, **2,187개, 건너뜀 11개, 실패 0**, 종료 코드 0. 로그 `/tmp/penguin-1.22.0-mac-tests.log`.
- Windows 코드의 로컬 검사: `cargo test --locked --offline --workspace --features tauri/macos-private-api -- --quiet`에서 **224개 통과, 4개 제외, 실패 0**. `cargo check --locked --offline --workspace --all-targets --target x86_64-pc-windows-gnu` 통과. 각각 `/tmp/penguin-1.22-native-final.log`, `/tmp/penguin-1.22-gnu-final.log`. Windows 운영체제에서 실행한 결과는 아닙니다.
- Node **33개 통과**, `check-ui-scripts.mjs` 3개 HTML 문법 검사 통과. 사용량 기간·페이스·한도, 날씨 현지 날짜/DST/도시 교체, 기존 주식·인증·한국어 동작을 확인했습니다. 로그 `/tmp/penguin-1.22-node-final.log`.
- Playwright Chromium: 설정 **24개 배치**, 노치 **48개 배치**, 쌍 수치 **48개 조합**, 업데이트 카드 **네 방향 × 원/막대·호버 1.5배**, 미리보기·나중에·다시 표시·확인 중 입력·설치 연속 클릭·진행률·포커스 검사가 통과했습니다. 각각 `test-settings-browser.cjs`, `test-notch-scroll-browser.cjs`, `test-updater-ui.cjs`. 네이티브 IPC는 공개 모의 자료이며 외부 API를 호출하지 않습니다. 실제 Windows WebView2·물리적 다중 모니터·실제 계정 검증을 대신하지 않습니다.
- 로컬 화면 로그: `/tmp/penguin-1.22-settings-final.log`, `/tmp/penguin-1.22-notch-final2.log`, `/tmp/penguin-1.22-updater-final2.log`. 저장된 설정·노치 화면도 직접 확인했습니다.
- 원격 빌드·정식 설치 파일·업데이트 서명·최종 자산 해시 결과는 완료 후 이 항목에 추가합니다.
- 후속 공개: [정식 v1.22.0](https://github.com/pmh10401/PenguinNotch/releases/tag/v1.22.0), 소스 [a1e1bd764248e2d120bf2cdb1c0b2bc7ff2eeb4e](https://github.com/pmh10401/PenguinNotch/commit/a1e1bd764248e2d120bf2cdb1c0b2bc7ff2eeb4e). [macOS CI](https://github.com/pmh10401/PenguinNotch/actions/runs/36514869787)는 **2,187개, 건너뜀 13개, 실패 0**, [Windows CI](https://github.com/pmh10401/PenguinNotch/actions/runs/36514869756)는 **228개 통과, 4개 제외, 실패 0**입니다. Windows CI에서도 같은 실제 HTML 화면 검사를 통과했습니다.
- [macOS 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/36514869785)의 DMG를 읽기 전용으로 마운트하여 1.22.0/build 61, macOS 15+, arm64·x86_64, 임시 서명 유효성, 디버그 entitlement 없음까지 확인했습니다. [Windows 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/36514869794)는 설치·doctor·제거와 서명된 업데이트 피드 생성에 성공했습니다.
- 기존 공개 키로 Sparkle Ed25519 및 Tauri Minisign 설치 파일·신뢰 주석의 서명을 검증하고, 한 바이트를 바꾸면 검증이 실패함을 확인했습니다. 비공개 서명 키는 내보내지 않았습니다. macOS Apple 공증 및 Windows Authenticode 서명과는 별개의 업데이트 검증입니다.
- [최종 Windows 배포 작업](https://github.com/pmh10401/PenguinNotch/actions/runs/36517687166)도 설치·doctor·제거·게시를 통과했습니다. 이 작업이 교체한 최종 설치 파일과 피드를 공개 최신 릴리즈 URL에서 다시 받아 두 업데이트 서명·변조 거부·GitHub 자산 해시를 검증한 뒤 [SHA256SUMS.txt](https://github.com/pmh10401/PenguinNotch/releases/download/v1.22.0/SHA256SUMS.txt)를 갱신했습니다. 공개된 해시 파일도 다시 내려받아 일치를 확인했습니다. 파일 자체의 SHA-256: `58d8b96e4fb0bbe0d42043472322347c61ff3ab4c5d5d37e70ae2caa62948d28`.

저장소 루트에서 추가된 UI 검사를 재현합니다. Playwright는 앱 의존성이 아니며 CI의 임시 검사 폴더에 고정 버전으로 설치합니다.

```sh
node --test windows/scripts/test-usage-display.cjs
node windows/scripts/test-settings-browser.cjs
node windows/scripts/test-notch-scroll-browser.cjs
node windows/scripts/test-updater-ui.cjs
```


## S13

- 확인: 2026-09-29 KST. 기준 `5a3d2772e230f179eef1228f55aaadd974b313cb` 이후의 1.22.1 작업 트리(macOS build 62, Windows r54). 정식 배포·사용자 설치본 교체는 수행하지 않았습니다.
- Grok 4.6 high가 격리된 작업 트리의 공개 소스를 읽고 회귀 검사·수정 패치를 작성했습니다. 편집 호출은 취소되어 파일에 반영되지 않았으므로 Codex가 출력 패치를 적용하고, 잘못된 달력 응답 처리와 검사 코드를 보완했습니다. 외부 에이전트에는 실제 계정·키·사용자 시세 로그를 제공하지 않았습니다.
- 재현: 현재가 101→99, 기준 종가 100에서 자동 갱신의 종가/달력 요청이 HTTP 503이면 기존 구현은 등락률과 방향 색상을 지웠습니다. macOS `StockQuoteTests.testAutomaticRESTKeepsCompletedCloseWhenLaterDailyReturns503`와 Windows 실제 Store의 공개 IPC 모의 응답에서 수정 전 실패·수정 후 통과했습니다. 실제 서비스가 왜 실패했는지는 확인하지 않았습니다.
- 색상: `NotchRenderTests.testStockHoverChangeBarKeepsGreenAndRedAgainstABlueAccent`에서 실제 SwiftUI 호버 화면의 픽셀을 검사했습니다. 상승·하락·보합을 확인하며 사용자 지정 파란색이 변동 막대를 덮지 않습니다.
- macOS: StockQuote/Chart/Forecast/ForecastJournal/TimingSignal, NotchRender, TooltipRender 집중 검사 **98개, 선택적 실제 Claude 검사 1개 제외, 실패 0**, 종료 코드 0. 키체인 이동 검사는 실행 대상에서 제외했습니다. 로그 `/tmp/penguin-stock-recovery/mac-final.log`.
- Windows: Node 주식·위젯·한국어·인증 UI·사용량 회귀 **23개 통과**, 3개 HTML 문법 검사 통과. Chromium의 실제 노치 HTML **48개 배치**, 네 방향·원/막대·75–150% 크기·호버·클릭·드래그·휠 검사 통과. Browser plugin이 제공되지 않아 설치된 Playwright를 사용했으며 공개 모의 IPC만 사용했습니다. 로그 `/tmp/penguin-stock-recovery/windows-regressions.log`, `/tmp/penguin-stock-recovery/windows-ui.log`; 화면 `/tmp/penguin-stock-recovery/windows-ui/right.png`, `top.png`.
- 제한: 실제 Toss 네트워크·사용자 자격 증명·Windows WebView2/기기는 검증하지 않았습니다. Rust 시세 전송·계정·영속 기록·예측 계산은 변경하지 않았으며, 이 로컬 검사는 새 Windows 네이티브 빌드나 원격 CI 결과가 아닙니다.
- 배포 전 추가 검사: 로컬 전체 Xcode 검사 2,193개 중 건너뜀 8개, 노치 이동 애니메이션 5개 검사에서 단언 7개가 실패했습니다. 같은 7개 애니메이션 검사만 다시 실행해도 동일했습니다. 주식·릴리즈 노트 검사는 통과했습니다. 실행 당시 macOS 세션의 화면 잠금이 확인되었으며, 이전 코드와의 비교 및 별도 macOS CI로 원인을 구분합니다. 로그 `/tmp/penguin-1.22.1-mac-full.log`, `/tmp/penguin-1.22.1-edge-recheck.log`.
- 이전 코드 비교: 변경 전 `5a3d277`의 Git 추출본을 별도 빌드 폴더에서 실행해도 동일한 5개 애니메이션 검사·7개 단언이 실패했습니다. 로그 `/tmp/penguin-1.22.0-baseline-edge.log`. 이번 주식 변경의 회귀로 판정하지 않으며, 잠금 해제 상태의 재현 여부는 미확인입니다. 애니메이션 코드를 바꾸거나 검사를 새로 제외하지 않았습니다.
- 첫 원격 검증: `27b1115`의 [macOS CI](https://github.com/pmh10401/PenguinNotch/actions/runs/36532295362)는 2,193개·건너뜀 13개 중 기존 200종목 묶음 요청 검사 하나에서 단언 3개가 실패했습니다. 바로 앞 자동 갱신 검사의 늦은 일봉 요청이 다음 검사의 공유 URLProtocol 기록에 섞였습니다. 테스트 세션마다 임의 식별자를 넣고 이전 세션 요청을 취소하는 회귀를 추가했으며, 실제 앱 전송 코드는 바꾸지 않았습니다. [Windows CI](https://github.com/pmh10401/PenguinNotch/actions/runs/36532295287)는 228개 통과·4개 제외, 두 패키지 작업도 성공했지만 이 커밋은 정식 배포하지 않았습니다.
- Grok의 추가 검토에서 Windows의 JSON 해석/응답 검증 실패가 일반 네트워크 실패와 함께 캐시를 재사용하는 차이를 확인했습니다. 네이티브의 기존 공개 오류 메시지를 사용해 잘못된 JSON·과대 응답·유효하지 않은 응답은 이전 달력으로 계산하지 않도록 보완하고 수정 전 실패·수정 후 통과를 확인했습니다. 호버의 다른 주식 정보 행은 원래 막대를 그리지 않아 색상 범위 변경은 필요하지 않았으며, 거래 구간 전환은 기존 공통 계산 함수의 회귀로 검증합니다.
- 후속 로컬 검증: 늦은 이전 세션 요청을 직접 보내는 새 검사는 격리 전 실패·격리 후 통과했습니다. StockQuote/NotchRender/TooltipRender 집중 검사 50개 중 선택적 실제 Claude 검사 1개 제외·실패 0, 종료 코드 0입니다. Windows stock 전체 검사와 JS 문법·공백 검사도 통과했습니다. 로그 `/tmp/penguin-1.22.1-fixture-red.log`, `/tmp/penguin-1.22.1-fixture-green.log`, `/tmp/penguin-1.22.1-calendar-red.log`, `/tmp/penguin-1.22.1-calendar-green.log`.
- 관련 구현: [Mac 갱신](../../Sources/Widgets/TossInvestClient.swift), [거래일·세션 검증](../../Sources/Widgets/StockQuote.swift), [호버 색상](../../Sources/Features/TooltipCard.swift), [Windows 갱신](../../windows/penguinnotch/ui/stocks.js). 재현 검사는 [Swift](../../Tests/StockQuoteTests.swift), [Windows](../../windows/scripts/test-stocks.cjs)에 있습니다.
- 검증 소스 SHA-256 `Sources/Widgets/TossInvestClient.swift`: `5fc23d4f432fd34df6b4729a0389ba6afe782495f23019bcff918b26290b904b`.
- 검증 소스 SHA-256 `Sources/Widgets/StockQuote.swift`: `c116d8a5dc42513b808898b6f151fa8d5faab58dbc82ddfbf66633d37e668174`.
- 검증 소스 SHA-256 `Sources/Features/TooltipCard.swift`: `b9ed543c5e1773f8a374949e3708e4736339805555be99d15919fef2cdd8865f`.
- 검증 소스 SHA-256 `windows/penguinnotch/ui/stocks.js`: `cdb1da136854704a71227a62f45b344502f61993a7412438298e0d3543a21ce6`.

Windows 회귀 검사는 저장소 루트에서 실행합니다. Playwright는 앱 의존성이 아니며 이미 설치된 환경에서만 사용합니다.

```sh
node --test windows/scripts/test-stocks.cjs windows/scripts/test-widgets.cjs windows/scripts/test-ko-i18n.cjs windows/scripts/test-claude-auth-ui.cjs windows/scripts/test-usage-display.cjs
node windows/scripts/check-ui-scripts.mjs
node windows/scripts/test-notch-scroll-browser.cjs
```

- 후속 정식 공개: [v1.22.1](https://github.com/pmh10401/PenguinNotch/releases/tag/v1.22.1), 최종 소스 [7621465f19e60c2beccf6b5e83034a08f950968d](https://github.com/pmh10401/PenguinNotch/commit/7621465f19e60c2beccf6b5e83034a08f950968d). [macOS CI](https://github.com/pmh10401/PenguinNotch/actions/runs/36533316180)는 **2,194개, 건너뜀 13개, 실패 0** 및 SwiftPM 고정 의존성 검사를 통과했습니다.
- [Windows CI의 두 번째 시도](https://github.com/pmh10401/PenguinNotch/actions/runs/36533316244/attempts/2)는 **228개 통과, 4개 제외, 실패 0**이며 JS·실제 HTML·Clippy 검사도 성공했습니다. 첫 시도에서는 이번에 변경하지 않은 `claude_auth::tests::failed_exit_and_timeout_are_reaped`의 5초 제한을 둔 PowerShell 정상 종료 확인 단언이 실패했습니다. 코드 변경 없이 같은 커밋을 한 번 재실행해 통과했으며, 시간 초과의 구체적인 시스템 원인은 확인하지 않았습니다.
- [macOS 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/36533316148)의 공개 DMG에서 1.22.1/build 62, macOS 15+, arm64·x86_64, 유효한 임시 서명과 디버그 entitlement 부재를 확인했습니다. [Windows 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/36533316346)의 설치·doctor·제거·서명 피드 생성도 성공했습니다.
- 기존 Sparkle 키를 내보내지 않고 `generate_appcast --account penguin-notch`를 한 번 호출해 피드를 생성했습니다. 공개 키만으로 두 설치 파일의 Sparkle Ed25519·Tauri Minisign 및 신뢰 주석 서명, 한 바이트 변조 거부를 확인했습니다. 이번 서명 호출에는 추가 사용자 인증 요청이 발생하지 않았습니다.
- 이 Mac 설치: `make install` 종료 코드 0. `/Applications/PenguinNotch.app` 1.22.1/build 62, arm64·x86_64, 기존 Apple Development 팀의 서명 검증과 단일 실행 프로세스를 확인했습니다. 실제 앱 접근성 화면에 1.22.1 새 기능 안내가 표시됐고 ‘계속’이 안내를 닫았습니다. 공개 DMG의 OS 서명·공증 상태와는 별개이며, 실제 계정 시세의 장시간 검증은 하지 않았습니다.
- 후속 최종 Windows 소스 SHA-256 `windows/penguinnotch/ui/stocks.js`: `686fa0f136f9aef2682d7ed7b55c37c09ffd0d22985c953651f5c5ea570c73e2`. 위 초기 해시는 이전 검증 시점의 기록으로 보존합니다.
- [릴리즈 후 최종 Windows 배포](https://github.com/pmh10401/PenguinNotch/actions/runs/36534413883)도 설치·doctor·제거·게시를 통과했습니다. 공개 최신 다운로드 주소에서 최종 네 파일을 다시 받아 두 서명·변조 거부·GitHub 자산 해시를 확인하고 [SHA256SUMS.txt](https://github.com/pmh10401/PenguinNotch/releases/download/v1.22.1/SHA256SUMS.txt)를 갱신했습니다. 해시 목록 자체의 SHA-256: `1033d013b5bf24e2dbfbd1e975b8a0111ab8568ccadcde307ad3da738469a4ce`.
