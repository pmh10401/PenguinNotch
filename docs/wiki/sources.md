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

## S14

### 2026-10-01 내 토스 계좌 뷰어

- 근거: [토스 공식 OpenAPI JSON](https://openapi.tossinvest.com/openapi-docs/latest/openapi.json), 명세 버전 **1.2.19**, 공개 다운로드 SHA-256 `7588debd863ac074e9e408185413ab573c3d45e9221e8cedaeec7c54ee295f03`. `/api/v1/accounts`, `/api/v1/holdings`와 HoldingsOverview/HoldingsItem/Price 및 MarketCountry/Currency의 unknown enum 규칙을 읽었습니다. 실제 사용자 응답·계좌 자료는 사용하지 않았습니다.
- 검증 대상: 기존 HEAD `dac45dc` 위의 **1.23.0/build 63, Windows r55 작업 소스**입니다. 정식 릴리즈·GitHub CI·새 Windows 설치 파일 게시를 수행하지 않았으며, 최신 정식 공개는 계속 v1.22.1입니다.
- macOS: 새 계좌 디코더/비동기 취소/숨김/오류/소수점/언어 표시와 기존 시세·예측·릴리즈 안내·언어의 집중 검사 **87개, 실패 0**. 정규식의 마지막 개행 우회 보완 후 계좌 검사 **9개, 실패 0**. 이후 두 플랫폼의 중간값 반올림을 half-up으로 맞추고 계좌 검사 10개를 다시 실행했습니다. 최종 계좌 검사 **10개, 실패 0**이며 Windows의 같은 반올림 경계도 검사했습니다.
- Windows: Node 관련 검사 **23개 통과, 실패 0**, 인라인 JS 구문 검사 통과. 영어·한국어 실제 settings.html 모의 브라우저에서 680×640·1024×640 화면으로 계좌 불러오기 → 직접 선택 → 새로고침 → 오류 시 스냅샷 제거 → 숨김 → 탭 이동 시 삭제를 검증했습니다. Browser 스킬/플러그인이 없어 기존 번들 Playwright를 사용했으며, 별도 의존성을 설치하지 않았습니다. 기존 설정 브라우저도 24개 배치 검사와 언어·키보드·저장 검사를 통과했습니다. 과대 표는 접근 가능한 가로 스크롤 영역 안에 표시합니다.
- Rust: 네이티브 주식 검사 **19개 통과**, Windows GNU 대상 `cargo check --locked` 통과. 저장소 CI와 같은 경고 허용 Clippy는 Windows GNU `--all-targets --locked` 종료 코드 0입니다. 별도로 실행한 macOS `-D warnings`는 플랫폼별 미사용 코드와 기존 스타일 경고를 오류로 처리해 실패했으며, 새 테스트 초기화 경고 한 건만 수정했습니다. 관련 없는 경고를 숨기거나 앱 코드를 바꾸지 않았습니다.
- 미검증: 실제 계좌의 접근 권한/금액 대조, Windows 실기 Credential Manager·WebView·설치 파일 실행, GitHub CI, 정식 배포. 이 화면은 조회 전용이며 주문·송금·영구 저장·CSV·AI 입력을 추가하지 않습니다.
- 공개 구현·검사: [Mac 계좌 모델](../../Sources/Widgets/TossAccountPortfolio.swift), [Mac 화면](../../Sources/Settings/TossAccountView.swift), [Mac 검사](../../Tests/TossAccountTests.swift), [Windows 전송](../../windows/penguinnotch/src/stocks.rs), [Windows 화면](../../windows/penguinnotch/ui/stocks.js), [Windows 검사](../../windows/scripts/test-stocks.cjs).
- 소스 SHA-256 `Sources/Widgets/TossAccountPortfolio.swift`: `1bc452ea40159681c18a305e75ccde3826cfcb13fefe7675e8d5c1333b786049`.
- 소스 SHA-256 `Sources/Settings/TossAccountView.swift`: `522273fb6855e5aeb5f4e154cbbebd2cb69d4a73a03026552b64d2bdcce1877e`.
- 소스 SHA-256 `Sources/Widgets/TossInvestClient.swift`: `1b168319fce93343cd7e1b680d52071d54d2ee2f35f6dcbf1953eb6505b509a6`.
- 소스 SHA-256 `windows/penguinnotch/src/stocks.rs`: `0ac5c9cc20418e106b8e86554c41540366a4826e91d2a704ec83d215cca00f04`.
- 소스 SHA-256 `windows/penguinnotch/ui/stocks.js`: `4b4cb40e08ac2a2bcc3d6c6c9f2ccc2e83299306a5ab2f8afce6925736faf897`.
- 최종 로컬 설치: `make install` 종료 코드 0, `/Applications/PenguinNotch.app` **1.23.0/build 63**, arm64·x86_64 및 `codesign --verify --deep --strict` 통과, 앱 실행 프로세스 확인. 기존 Apple Development 서명을 사용했으며 Sparkle 서명·GitHub 정식 릴리즈를 호출하지 않았습니다. 계좌 화면의 실제 사용자 응답/금액 대조는 하지 않았습니다.
- 문서 로컬 링크 137개와 기존 문자열 카탈로그 1,501개 보존을 확인했습니다. GitHub 상대 릴리즈·Actions 링크는 로컬 파일 검사에서 제외했습니다. 계좌 관련 새 번역 26개를 추가했습니다.

## S15

### 2026-10-01 계좌 노치와 중복 작업 최적화

- 기준: 커밋 `dac45dca5a1d0a7052065032fbfee84cfefb8d6d` 후속 작업 트리, macOS 1.24.0/build64 및 Windows 1.24.0/r56 소스. S14의 뷰어 수명 규칙을 명시적 계좌 노치 opt-in으로 보완합니다. 정식 공개 릴리즈는 별도입니다.
- 공식 근거: [OpenAPI 1.2.19](https://openapi.tossinvest.com/openapi-docs/latest/openapi.json)의 Asset/holdings. 주식 자산의 통화별 합산금액·손익과 원화 환산 손익률이며 현금 포함 계좌총액 API로 해석하지 않습니다.
- 개인 계좌나 인증 정보는 기록하지 않습니다. 검증 입력은 공개 명세를 기반으로 한 모의 응답입니다. Grok 읽기 전용 검토에서 공유 뷰 수명과 네이티브 계좌 발견 집합 경계를 확인했습니다. 별도 Mac 토큰 캐시 제안은 기존 `TossInvestAPI.accessToken`이 이미 공유 캐시·in-flight 합류를 제공하므로 채택하지 않았습니다.
- 구현: 기본값은 꺼짐이며 예측의 계좌 선택과 독립적입니다. 직접 불러온 계좌를 선택하고 노치 표시를 켜면 60초마다 조회합니다. 같은 계좌의 조회 중에는 기존 화면을 유지하고, 실패·숨김·제공처/인증 변경 시에는 이전 금액을 지웁니다. 늦은 응답은 세대 검사로 폐기합니다. 설정 화면을 닫아도 명시적으로 켠 노치는 유지하며, ‘계좌 정보 숨기기’는 노치를 끄고 조회를 중단합니다. 저장하는 설정은 표시 여부와 불투명 계좌 선택 번호뿐입니다.
- 최적화: Mac 설정과 노치가 같은 저장소·기존 토큰 캐시를 재사용하고 중복 요청을 합칩니다. 고정 계좌 셀에는 주식 가격/등락률 교대 타이머를 만들지 않습니다. Windows 계좌 뷰어는 변하지 않은 공개 시세 갱신에서 다시 그리지 않습니다. 실제 Chromium의 `Store.changed()` 1,000회에서 개인 계좌 뷰어 DOM 변경 **0회**를 확인했습니다. 이 관찰을 CPU 사용률 개선 수치로 해석하지 않습니다.
- macOS: 계좌·시세·예측·언어·릴리즈 안내·스크롤 회귀 **103개, 실패 0**. 최종 계좌/호버 렌더링 검사 **28개 중 건너뜀 1개, 실패 0**이며 계좌 검사 17개를 포함합니다. 두 실행의 중복 검사를 더해 고유 검사 수로 표시하지 않습니다. 영어·한국어 ImageRenderer 화면에서 원형·막대·가로 읽기와 통화별 호버 값을 확인했습니다. 초기 렌더링 fixture의 환경 API/다크 모드 설정 오류는 테스트만 수정하고 후속 검사를 통과했습니다.
- Windows: 최종 Node 관련 검사 **23개 통과, 실패 0**, 인라인 JS 구문 검사 통과. 실제 notch.html의 영어·한국어 × 네 방향 × 원형/막대 **16개 계좌 화면**과 **16개 과밀 목록 스크롤**에서 계좌 셀 도달·호버 화면 경계·오류 후 수동 재조회·숨김을 검사했습니다. 모의 시계를 바꾸거나 실패 재시도 상태를 초기화하지 않고 수동 새로고침 복구를 확인했습니다. 추가로 실제 settings.html의 680×640·1024×640 네 가지 계좌 흐름, 기존 설정 24개 배치 검사와 노치 48개 배치 회귀를 통과했습니다. 모든 브라우저 요청은 로컬 파일/모의 IPC에 한정했습니다.
- 실제 화면 검사에서 Windows 통화 표의 금액 잘림과 한국어 계좌 라벨의 줄바꿈을 발견해 네 개 세로 행과 계좌 라벨의 폭 규칙으로 보완했습니다. 다른 셀의 배치는 바꾸지 않았습니다. Browser 플러그인이 없어 기존 번들 Playwright를 사용했고 새 의존성을 설치하지 않았습니다.
- Rust: Mac 호스트의 네이티브 주식 검사 **21개 통과, 실패 0**. Windows GNU 대상 `cargo check --locked`와 저장소 CI 방식의 `cargo clippy --all-targets --locked` 종료 코드 0입니다. 각각 기존 경고 4개·17개가 남아 있으며 경고 없는 빌드나 Windows 실기 검사로 표현하지 않습니다. 계좌 목록 재조회 실패가 현재 인증의 기존 발견 집합을 지우지 않는 회귀도 검사했습니다.
- 로컬 설치: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make install` 종료 코드 0. `/Applications/PenguinNotch.app` **1.24.0/build 64**, arm64·x86_64, `codesign --verify --deep --strict` 및 해당 경로의 실행 프로세스를 확인했습니다. 기존 Apple Development 팀 서명을 유지했습니다. Sparkle 키 접근·업데이트 피드 서명·GitHub 게시를 수행하지 않았습니다.
- 미검증: 실제 사용자 계좌의 금액/손익률 대조, Windows 실기의 Credential Manager·WebView·설치본, GitHub CI와 정식 배포. 현금 포함 계좌총액이나 자체 환산 합계, 비공개 계좌 이력·CSV·AI 전송은 추가하지 않았습니다.
- 문서 로컬 링크 142개·누락 0, 기존 문자열 카탈로그 1,501개 항목의 값 보존과 최종 1,537개 항목을 확인했습니다. 두 플랫폼 버전·빌드 번호와 아래 여덟 소스/검사 해시도 최종 파일에 대조했습니다.
- 소스 SHA-256 `Sources/Widgets/TossAccountPortfolio.swift`: `ea76633a8f7c44176cd84b517a307576c48e24d700ca1579af9a63911b07b4e7`.
- 소스 SHA-256 `Sources/Settings/TossAccountView.swift`: `f266a27c88a4a92cd2b8270d7d8d986998b1c733be720a843716d26994281c47`.
- 검사 SHA-256 `Tests/TossAccountTests.swift`: `643cb467d31ca35fb1b313bee1362be8dcb4e4c855e109181b191c96e3ffe378`.
- 소스 SHA-256 `windows/penguinnotch/src/stocks.rs`: `4b06b871bf3f0df8f61f19ad37726a5284a09937638053de23d57bb5412e7c31`.
- 소스 SHA-256 `windows/penguinnotch/ui/stocks.js`: `25de25663f1a36f275895ef6f60b2bfe59a368a4e15cdf8417ca478afb765889`.
- 소스 SHA-256 `windows/penguinnotch/ui/stocks.css`: `13d9d84992771fc31cd9eb7697310811a03c5f203563a137ea23f1f96a6c8826`.
- 소스 SHA-256 `windows/penguinnotch/ui/notch.html`: `de719f107db823fcb0a94b3b15d92cf0c8aca12605867124eadd35c25de584b8`.
- 검사 SHA-256 `windows/scripts/test-stocks.cjs`: `63fb448116a4dc50fee75e8e2d3d200f22105fd34b08f18b3a9389b79534b4b2`.

관련 검사는 저장소 루트에서 실행합니다. Windows 교차 검사에는 설치된 GNU 도구 체인이 필요하며, 실제 Windows 실행 검사를 대신하지 않습니다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PenguinNotch.xcodeproj -scheme PenguinNotch -destination 'platform=macOS,arch=arm64' -only-testing:PenguinNotchTests/TossAccountTests test
node --test windows/scripts/test-stocks.cjs windows/scripts/test-widgets.cjs windows/scripts/test-ko-i18n.cjs windows/scripts/test-claude-auth-ui.cjs windows/scripts/test-usage-display.cjs
node windows/scripts/check-ui-scripts.mjs
cargo test --manifest-path windows/Cargo.toml -p penguinnotch --locked --features tauri/macos-private-api stocks::tests::
cargo check --manifest-path windows/Cargo.toml -p penguinnotch --locked --target x86_64-pc-windows-gnu
```

## S16

### 2026-10-01 주식 설정의 정보 밀도와 중복 조작 개선

- 기준: `dac45dca5a1d0a7052065032fbfee84cfefb8d6d` 후속 작업 트리, **1.24.1/build 65·Windows r57** 소스입니다. S14·S15의 계산·보관·조회 규칙은 유지하고 설정의 구성과 계좌 선택 조작을 보완합니다. 현재 정식 공개 릴리즈와 이 로컬 설치를 구분합니다.
- 현재 화면 캡처 근거: 기존 실제 Windows settings.html에 모의 IPC를 연결해 880×700 영어·한국어 화면을 확인했습니다. 주식 입력칸으로 자동 포커스/스크롤되면서 상단 설정이 가려졌고, 계좌·차트·예측·이력이 한 페이지에 이어졌습니다. 과거 캡처나 실제 계좌 자료를 감사 입력으로 사용하지 않았습니다.
- 개선 흐름: 관심 종목 → 내 계좌 → 분석 → 기록. 첫 탭에서 종목을 추가하고, 계좌는 한곳에서 불러와 직접 선택하며, 차트·분석·예측과 저장 결과는 별도 화면에서 확인합니다. 표시·연결·이동평균·분석 방식·세부 손익·보유 종목은 기본 접힘입니다. Windows는 방향키·Home/End·aria tab 속성과 탭별 스크롤/포커스를 제공하며 같은 계산·기록 API를 재사용합니다.
- 계좌 선택 경계: 화면 열기·목록 읽기에는 저장된 선택값을 그대로 유지합니다. 계좌 노치와 보유 종목 예측 포함은 각각 명시적으로 켜며 예측 기능 자체는 자동으로 켜지 않습니다. 다른 계좌를 직접 선택하면 이미 켜진 계좌 기능이 그 선택을 따릅니다. 계좌를 다시 읽지 않고 기존 보유 종목 포함을 끌 수 있습니다. 내 계좌에서 떠나는 동작은 개인 뷰어만 지우며 활성화된 노치나 이력을 지우지 않습니다.
- Grok 읽기 전용 검토: 세대/선택값 보존, 탭 이탈과 명시적 숨김의 차이, 계좌 오류가 분석 화면에서 사라질 위험, 포커스/상세 상태를 확인했습니다. 저장된 선택을 0으로 초기화하거나 탭 변경을 ‘계좌 정보 숨기기’로 처리하지 않습니다. Mac의 예측 계좌 오류는 분석 화면에 남기고 Windows도 액션별 상태 영역을 유지합니다. 기존 API 키·개인 자료를 전달하지 않았습니다.
- macOS 검증: 계좌·시세·예측·릴리즈 안내·언어 검사 **97개, 실패 0**, 종료 코드 0입니다. 새 네 페이지의 영어·한국어 네이티브 뷰 렌더링과 실제 계좌 선택 핸들러를 실행했습니다. 페이지 렌더링이 계좌 요청을 만들거나 서로 다른 저장 선택을 바꾸지 않는지, 명시적 계좌 변경/해제와 독립 opt-in을 검사합니다.
- 검사 차이 보존: 초기 계좌 요약 검사는 이전 기본 높이 >500px 단언 두 번이 실패했습니다. 의도적으로 상세를 접은 현재 화면은 436px이므로 기본 요약이 300–500px 범위로 줄었음을 검사하도록 바꾸고 후속 전체 집중 검사를 통과했습니다. 오프스크린 AppKit 캐시 이미지의 상단 segmented control은 빈 흰 영역으로 캡처되어 그 부분을 시각 근거로 채택하지 않았습니다. 실제 `/Applications/PenguinNotch.app` 화면과 접근성 트리에서 네 탐색 항목의 표시·선택 상태 및 관심 종목 화면을 별도로 확인했습니다.
- Windows 검증: Node **23개 통과**, 인라인 JS 구문 검사 통과. 실제 HTML의 영어·한국어 × 680/1024×700 네 흐름에서 첫 뷰포트·네 탭·키보드·비밀 입력 제거·자동 계좌 접근 없음·명시적 선택·오류 재조회·개인 뷰어 제거·선택 탭/언어 상태를 검사했습니다. 선택한 계좌의 뷰어를 공개 갱신 1,000회에서 다시 만들지 않았습니다. 기존 설정 브라우저도 24개 배치 검사·저장·키보드·표시/순서 회귀를 통과했습니다. 기존 자동 입력칸 포커스 단언은 새 탭 포커스와 상단 탐색 도달 단언으로 교체했습니다.
- 플랫폼 경계: GNU Windows 대상 `cargo check --locked` 종료 코드 0, 기존 경고 4개. 네이티브 전송/이력 코드는 이 UX 작업에서 바꾸지 않았습니다. 실제 Windows WebView2·설치본·Credential Manager, 실제 계좌 금액/손익률 대조, 모든 보조기술의 접근성 적합성, GitHub CI·정식 배포는 미검증입니다. Codex 분석은 macOS 전용이며 Windows에 동작하지 않는 버튼을 추가하지 않았습니다.
- 로컬 설치: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make install` 종료 코드 0, `/Applications/PenguinNotch.app` **1.24.1/build 65**, 기존 서명 검증과 해당 경로의 실행 프로세스를 확인했습니다. 새 기능 안내도 해당 버전/한국어로 나타났습니다. 실제 UI 관찰에는 계좌 불러오기·인증 변경·CSV 내보내기를 사용하지 않았고 개인 자료를 문서에 기록하지 않았습니다.
- 최종 로컬 문서 링크 146개·누락 0, 원래 문자열 카탈로그 1,501개 값 보존과 최종 1,558개를 확인했습니다. 새 Mac EN/KO 키 21개와 두 플랫폼 버전·빌드 번호·아래 해시는 최종 파일에 대조했습니다.
- 소스 SHA-256 `Sources/Settings/StockSettings.swift`: `83ec9c42064d0a40f99da6e204e610869300712225b78cc2cab0858421fc7878`.
- 소스 SHA-256 `Sources/Settings/TossAccountView.swift`: `f224dc427ac541b2b84ebe31337503507f8b1669c851f454f616cc87bac3a553`.
- 검사 SHA-256 `Tests/TossAccountTests.swift`: `b6880c5c4d29ddaf6b1f38f2539396f2e975fb64cd00aa2e5c08d6be63ba4256`.
- 소스 SHA-256 `windows/penguinnotch/ui/stocks.js`: `1d24bbc801523a75cea76b732efa8bdc976a0ceaacb62da689998a75016c007e`.
- 소스 SHA-256 `windows/penguinnotch/ui/stocks.css`: `1b1e44656095dd7e5a7347716dbd89df0b55cb4d8a9985f20608a4dc1e93d9bf`.
- 검사 SHA-256 `windows/scripts/test-stocks.cjs`: `2ea98bfc49488d0a8c7c76f93225cd7ea055d69bf599c17094c2a92bbac2b317`.
- 검사 SHA-256 `windows/scripts/test-settings-browser.cjs`: `719ec25d0d8e13e1222e26d63dab25aace74818e8012b0be95cc61c43cc80adc`.

현재 UI 회귀 검사는 다음과 같이 실행합니다. 브라우저 검사는 이미 설치된 Playwright를 사용하며 네이티브 Windows 실행과 구분합니다.

```sh
node --test windows/scripts/test-stocks.cjs windows/scripts/test-widgets.cjs windows/scripts/test-ko-i18n.cjs windows/scripts/test-claude-auth-ui.cjs windows/scripts/test-usage-display.cjs
node windows/scripts/check-ui-scripts.mjs
node windows/scripts/test-settings-browser.cjs
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PenguinNotch.xcodeproj -scheme PenguinNotch -destination 'platform=macOS' -configuration Debug -only-testing:PenguinNotchTests/TossAccountTests -only-testing:PenguinNotchTests/StockForecastTests -only-testing:PenguinNotchTests/StockQuoteTests -only-testing:PenguinNotchTests/ReleaseNotesTests -only-testing:PenguinNotchTests/AppLanguageTests CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test
```

## S17

### 2026-10-01 1.24.1 정식 릴리즈

- 고정 소스: [`9006504b8a67a8e4a73882548a93467ab3fd8c49`](https://github.com/pmh10401/PenguinNotch/commit/9006504b8a67a8e4a73882548a93467ab3fd8c49), [v1.24.1](https://github.com/pmh10401/PenguinNotch/releases/tag/v1.24.1). macOS **1.24.1/build 65**, Windows **1.24.1/r57**입니다. 2026-10-01 08:07:03 UTC에 정식 공개했으며 S14–S16의 계좌 뷰어·노치·네 탭 개선을 포함합니다. 이전 항목의 미배포 기록은 해당 검증 시점의 사실로 보존합니다.
- 로컬 macOS 전체 검사: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test-ci`, **2,213개 중 선택적 11개 건너뜀·실패 0**, 종료 코드 0. [macOS CI](https://github.com/pmh10401/PenguinNotch/actions/runs/36831487263)는 같은 소스에서 **2,213개 중 선택적 13개 건너뜀·실패 0**, 고정 SwiftPM 의존성 검사도 통과했습니다. 서로 겹치는 로컬·원격 검사를 합산하지 않습니다.
- [Windows CI](https://github.com/pmh10401/PenguinNotch/actions/runs/36831487374): **232개 통과·선택적 4개 제외·실패 0**, Clippy와 실제 Chromium의 설정 24개·노치 48개 배치 및 업데이트 UI 검사를 통과했습니다. 영어·한국어, 네 방향, 원형/막대, 75–150% 크기, 휠·포인터·정렬 회귀를 포함합니다. HTML 모의 IPC 검사는 실제 개인 계좌나 Windows 자격 증명 동작의 증거로 사용하지 않습니다.
- 초기 [macOS 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/36831487341)와 [Windows 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/36831487387)는 같은 고정 소스에서 성공했습니다. Windows 러너의 NSIS 설치·doctor·제거 및 서명된 업데이트 피드 생성도 통과했습니다. DMG 내부 버전·build·macOS 15 최소 조건·arm64/x86_64·내장 업데이트 공개 키/URL, 코드 서명 검증과 디버그 권한 부재를 확인했습니다.
- Sparkle 개인 키를 내보내지 않고 기존 `generate_appcast --account penguin-notch`를 **한 번** 호출했습니다. 사용자가 macOS 키체인 창을 직접 승인한 뒤 종료 코드 0을 확인했습니다. 암호나 개인 키를 채팅·Git·로그에 기록하지 않았습니다. 공개 키로 설치 파일의 Sparkle Ed25519·Tauri Minisign/신뢰 주석과 변조 거부를 검사합니다. 현재 Sparkle 피드는 enclosure의 DMG를 서명하며 XML 자체의 분리 서명이 있다고 주장하지 않습니다.
- Grok에 공개 코드만 전달한 읽기 전용 검토 후 계좌 선택 보존·명시적 해제·탭 이탈 수명·소수점 표시를 기존 회귀와 대조했습니다. 확인된 추가 차단 문제는 없었으며 사용자 금융값·인증 파일·연구 자료를 전달하거나 변경하지 않았습니다. 기존 계좌 이력·앱 코드·버전은 이 릴리즈 기록 후속 작업에서 바꾸지 않습니다.
- 배포 한계: 공개 Mac DMG는 임시 서명되며 **Apple 공증을 받지 않았습니다**. Windows 설치 파일은 **Authenticode 인증서가 없습니다**. 업데이트 서명과 OS 첫 설치 경고는 별개입니다. 실제 계좌 금액/손익률 대조, 사용자 Windows 기기의 WebView2·Credential Manager·모니터 동작은 미검증이며 Codex 수동 분석은 macOS 전용입니다. 이 Mac의 기존 Apple Development 서명 설치본 1.24.1/build 65는 공개 DMG로 덮어쓰지 않았습니다.
- [릴리즈 후 최종 Windows 배포](https://github.com/pmh10401/PenguinNotch/actions/runs/36834349508)도 같은 소스의 설치·doctor·제거·설치 파일 게시·피드 게시를 모두 통과했습니다. 초기 패키지와 최종 릴리즈 실행의 자산을 섞지 않고, `releases/latest/download/`에서 받은 네 파일을 최종 게시 자산과 대조했습니다. 모든 URL의 HTTP 200, 두 설치 파일의 공개 키 서명·한 바이트 변조 거부, 피드 버전·URL·GitHub 자산 해시를 확인했습니다.
- 최종 Windows 파일 변경에 맞춰 [SHA256SUMS.txt](https://github.com/pmh10401/PenguinNotch/releases/download/v1.24.1/SHA256SUMS.txt)를 갱신했습니다. 게시한 해시 목록 자체의 SHA-256은 `e94cf91b3b682fdc3df569b186b97a0ed01bb5d351a947db70fe45df18963708`이며 공개 최신 주소에서 다시 받은 내용과 정확히 일치합니다. GitHub의 latest는 v1.24.1이며 다섯 자산이 모두 공개 상태입니다.
- 최종 파일 SHA-256: DMG `7e6e369e391503a898497a072007daaf140bbdb6a49b72d8e720732c74fc6903`, appcast `835375ca7f9bed0b091fa93e9173ad79e5f46182d6782b20479262214b9d55b9`, EXE `02c25a5260178719d9e6d71d293ab89fe489dd3ef63514b90e45042b750b52d0`, latest.json `3db1d9ad4507d60dc8f805fb88c18b29df40cbe3d88db816c96437980e96025a`.

## S18

### 2026-10-02 정규장 종가 예측의 기록·평가 계약 검수

- 코드 기준: [`92ddece9aa88d7c2206753e13ee9fe1239603bab`](https://github.com/pmh10401/PenguinNotch/commit/92ddece9aa88d7c2206753e13ee9fe1239603bab), 앱 1.24.1. [GBM과 봉별 추정](../../Sources/Widgets/StockForecast.swift), [기록·점수·대응 비교](../../Sources/Widgets/StockForecastJournal.swift), [Codex 입력과 같은 입력의 GBM](../../Sources/Widgets/StockCodexAnalysis.swift), [기술적 신호](../../Sources/Widgets/StockTimingSignal.swift), [Windows 함수](../../windows/penguinnotch/ui/stocks.js)를 읽었습니다.
- [일반 이력 화면](../../Sources/Settings/StockForecastHistoryView.swift)은 GBM 저널을, [Codex 이력 화면](../../Sources/Settings/StockCodexAnalysisView.swift)은 별도 저장소를 읽습니다. 두 모델의 수동/자동 시점과 근거를 보존하며 비교해야 합니다. 분봉 추정의 확률/구간은 별도 성과 이력에 저장하지 않으며 현재 모든 모델 교집합 규칙에는 모델 추가 시 대응 표본이 감소하는 한계가 있습니다.
- 가격 단위: [TossInvestClient](../../Sources/Widgets/TossInvestClient.swift)의 입력 일봉은 `adjusted:true`, 당시 실제 종가의 후속 조회는 `adjusted:false`입니다. 이는 당시 시세와 목표 종가의 관측 단위를 유지하려는 기존 규칙입니다. 이를 사후 조회한 수정주가와 임의로 섞는 새 백테스트는 별도 검증이 필요합니다.
- 공식 자료: [토스 OpenAPI](https://openapi.tossinvest.com/openapi-docs/latest/openapi.json), 1.2.19, SHA-256 `7588debd863ac074e9e408185413ab573c3d45e9221e8cedaeec7c54ee295f03`. 캔들 interval은 1m/1d, 최대 200봉, before/nextBefore와 수정 옵션, 날짜별 KR/US 거래 달력 명세를 확인했습니다. 이 확인은 과거 분봉의 실제 제공 기간·완전성이나 사용자 인증 요청 성공을 증명하지 않습니다.
- 방법론: [Hyndman·Athanasopoulos의 시간 순서 교차 검증](https://otexts.com/fpp3/tscv.html)은 각 예측 시점 이전 관측만 사용하는 반복 평가를 설명합니다. [Look-Ahead-Bench](https://arxiv.org/abs/2601.13770)는 금융 LLM의 학습 정보와 시간 누출을 연구합니다. 특정 현재 모델의 누출이나 주가 예측 성공을 확인했다는 근거로 사용하지 않습니다.
- Grok은 지정된 공개 코드만 읽어 비교 집합·사후 LLM 재실행·수정 가격·분봉 근거·확률 사건의 다섯 위험을 제시했고 Codex가 호출 흐름과 대조했습니다. 기대값과 확률의 부호가 다르다는 지적은 분포의 비대칭성과 구분하며 그 자체를 응답 오류로 단정하지 않습니다. 계좌·인증·사용자 이력·미추적 연구 산출물은 전달하지 않았습니다.
- 로컬 저장 기록의 읽기 전용 감사는 별도 로컬 보고서에 두었습니다. Windows의 실제 `validForecast`/`score` 함수로 변환 입력을 검사해 집계와 대조했습니다. 첫 검사 어댑터의 존재하지 않는 반환 필드 단언은 실제 `accuracy` 필드로 바꿔 후속 검사를 통과했으며 앱 코드는 변경하지 않았습니다. 새 과거 시세 수집·모델 호출·Swift 빌드·Windows 실기·통합 기능 구현·설치·릴리즈는 수행하지 않았습니다.
- 범위 승인 후 [정규장 종가 예측 통합·평가 설계](../superpowers/specs/2026-10-02-stock-forecast-evaluation-design.md)를 작성했습니다. 기존 이력 보존, 60분 전 cutoff, 같은 입력의 봉별 계산, 별도 재현 아카이브와 선택 모델 대응 비교를 명세합니다. 이는 검토용 문서이며 미래의 구현·과거 자료 확보·검증 성공을 입증하지 않습니다.

## S19

### 2026-10-02 1.25.0 개발 소스의 최종 오프라인 검증

- 승인된 [설계](../superpowers/specs/2026-10-02-stock-forecast-evaluation-design.md)·[계획](../superpowers/plans/2026-10-02-stock-forecast-evaluation.md)의 Task1–6 구현과 각 독립 검토를 완료했습니다. Task7 시작 기능 기준은 로컬 `6905c55c5596b58a7e718871783af7579da2cdbe`입니다. 개발 버전은 **1.25.0 / Mac66 / Windows r58**이며 정식 공개 버전 **1.24.1**은 유지합니다. 이 기록은 로컬 검증이며 원격 CI·릴리즈·설치를 입증하지 않습니다. 이 시점에 예정했던 Task7/전체 브랜치 독립 검토·공개 코드 Grok 검토와 후속 보완의 결과는 [S20](#s20)에 기록합니다.
- 공개 구현: [Swift 평가](../../Sources/Widgets/StockForecastEvaluation.swift), [재현 계산·아카이브·수집](../../Sources/Widgets/StockBacktest.swift), [통합 기록 화면](../../Sources/Settings/StockForecastHistoryView.swift), [재현 화면](../../Sources/Settings/StockBacktestView.swift), [Windows 평가](../../windows/penguinnotch/ui/stocks.js), [Windows 재현](../../windows/penguinnotch/ui/backtests.js), [native 보존 저장](../../windows/penguinnotch/src/backtests.rs). 원본 입력/결과 바이트의 SHA-256 연결, 입력만 받는 계산, 목표만 읽는 평가, 수정주가 기준, 취소·명시적 재개·누락 분모를 검사합니다. 사용법은 [주식 규칙](stocks.md#1250-개발-소스의-통합-평가와-과거-재현)에 있습니다.
- [공유 합성 fixture](../../Tests/Fixtures/stock-forecast-evaluation-v1.json)의 SHA-256은 `9f0b6b7f6a60338352d76355c0a9678b40ab3438232fc4c7bf08c29bb73dad4f`입니다. DST·조기 종료·KR 세션, 세 모형, pending·통화·확률/구간 경계·선택 집합·중복 출처를 대조합니다. 가격 상대 오차 1e-8, 확률/집계 차이 1e-6 이내의 공개 합성 대조이며 실제 예측 성과나 사용자 집계가 아닙니다.
- **최종 Swift 전체는 한 번 실행하여 2,260개 중 8개 skip, 두 테스트에서 17개 assertion 실패(exit 65)**였습니다. `ReleaseNotesTests.testTheCurrentVersionHasANote`는 1.25.0 노트 누락(1개), `TossAccountTests.testStockSettingsPagesRenderWithoutReadingAccountsOrChangingSavedChoices`는 680×640 포인트를 Retina의 1360×1280 픽셀과 비교한 기존 fixture 가정(8개 렌더 × 2개 단언)입니다. 승인된 좁은 수정으로 현재 버전의 사실에 맞는 노트를 추가하고 정확한 포인트 크기와 `window.backingScaleFactor`에 따른 픽셀 크기를 함께 단언했습니다. 계좌 요청 0·선택값 불변·원래 캡처 경로를 유지했습니다. 이후 **ReleaseNotes 7개 + 해당 설정 검사 1개 = 8개 통과, 실패/skip 0(exit 0)**입니다. 전체 suite를 재실행하지 않았으므로 새 전체 통과로 표현하지 않습니다.
- 전체 Swift에서 관련 suite는 모두 실패 0입니다: Evaluation15, Backtest32, Forecast17, Chart15, Journal10, CodexAnalysis11, Quote30, Timing7. 별도 CodexRunner9는 live1 skip·실패0입니다. 이 수치는 전체 2,260개에 포함하며 다시 합산하지 않습니다. 8개 skip은 Amp·Apify·Devin·LMStudio·weather·Ollama·Codex arithmetic·Claude reset의 opt-in 실서비스 검사입니다. 전체/집중 명령에서 해당 opt-in 환경변수를 모두 해제했으며 활성화하지 않았습니다.
- **Mac-host Rust 전체: 245개 통과·실패 0·4개 ignored(exit 0)**, hook binary는 0개입니다. 제외한 것은 실제 AGY quota, 화면 읽기, native Codex quota, Claude renewal입니다. **최신 GNU workspace/all-target 잠금·오프라인 컴파일도 exit 0**이며 Task4 native gate/per-market 수정까지 포함합니다. Mac-host Rust 실행과 Windows 교차 컴파일을 실제 Windows 실행으로 표현하지 않습니다.
- Node/UI는 이후 변경하지 않은 최신 Task5/6 기록을 재사용합니다: 재현 전체28/28(Task5), Task6 UX5/5, fix1 관련8/8, fix2 관련10/10 및 마지막 변경 단언4/4는 서로 겹치는 범위입니다. stock umbrella11 PASS 그룹, widgets1/1, ko7/7, fake auth UI1/1, inline syntax가 통과했습니다. 실제 Chromium 설정24개 배치·노치48개 배치, fix1 focus/units, 최신 fix2 listing/union이 통과했으며 모의 IPC·외부 요청 abort를 사용했습니다. 서로 다른 시점의 검사를 합산하거나 최신 전체 Node/browser를 다시 실행했다고 주장하지 않습니다.
- Task6의 최신 네이티브 렌더는 공개 임시 저장소를 주입한 EN/KO history/replay/Codex 진입점 6개 NSHostingView bitmap과 본문 픽셀·로컬 Vision label 검증입니다. ImageRenderer가 헤더만 남긴 초기 근거는 대체되었습니다. 화면 밖 캡처는 실제 창 키보드·닫기 조작 검증이 아닙니다.
- 출력은 pristine하지 않습니다. 기존 Xcode CoreDevice/CoreSimulator 지원 진단, AppIntents metadata 생략·linkd/autoShortcut/XPC, SwiftUI 상태 접근, 로컬 Vision TextRecognition E5 및 일부 AppKit window/환경 진단이 남습니다. 집중 재컴파일에는 기존 Swift6 actor/Sendable·불필요한 nonisolated(unsafe)·Void 추론 진단과 unsigned strip-bitcode 생략도 있습니다. Rust는 Mac 기존 unused/dead-code8개, GNU normal4/test1개 경고를 유지합니다. 무관한 경고 수정을 하지 않았습니다.
- [Windows workflow](../../.github/workflows/windows.yml)의 push/PR 경로에 fixture와 project.yml을 포함하고 Node backtest 단계를 연결했습니다. Node 단언은 project.yml·Cargo.toml·tauri.conf.json·Cargo.lock의 버전 일치를 확인합니다. 실제 동일 명령·YAML 구조 검사 exit0이며 fixture만 변경돼도 Windows 검사가 선택됩니다. 버전·기존 lock/Package.resolved·Info.plist는 Task7에서 그대로입니다. 생성 프로젝트의 소스 목록이 맞아 재생성/정리를 하지 않았습니다.
- **실자료 probe는 UNPERFORMED**입니다. 안전한 기존 비대화형 인증을 입증하지 못했으며 인증·계좌·실제 제공처 조회를 실행하지 않았습니다. 실제 분봉 제공 기간·확보율·최종 종가와 당시 수정 버전, 사용자 Windows WebView2/Credential Manager·권한, 이 브랜치의 원격 CI는 미검증입니다. 개인 아카이브/집계·비밀·TEST 라벨은 공개 문서에 포함하지 않습니다. 순위·자동 모델 채택·매매 수익률 주장도 없습니다.

대표 오프라인 명령(저장소 루트, 기존 의존성/생성 프로젝트 사용):

```sh
env -u PENGUINNOTCH_LIVE_CODEX_TEST -u CODENOTCH_TEST_APIFY_LIVE -u CODENOTCH_TEST_AMP_LIVE -u PENGUINNOTCH_TEST_DEVIN_LIVE -u PENGUINNOTCH_OLLAMA_LIVE -u PENGUINNOTCH_LMSTUDIO_LIVE -u PENGUINNOTCH_LIVE_WEATHER_TEST -u CLAUDE_RESET_LIVE_RENDER_PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PenguinNotch.xcodeproj -scheme PenguinNotch -destination 'platform=macOS' -configuration Debug -derivedDataPath build/forecast-evaluation-tests -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile test CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
cargo test --locked --offline --manifest-path windows/Cargo.toml --workspace --features tauri/macos-private-api
cargo check --locked --offline --manifest-path windows/Cargo.toml --workspace --all-targets --target x86_64-pc-windows-gnu
```

Swift 실패 원본·집중 GREEN·정확한 명령/종료 코드·로그/해시·겹치는 Node/browser 근거는 로컬 Task7 report에 보존합니다. 전용 Xcode/Rust 캐시는 삭제하지 않고 종료 후 controller에 반환합니다.


## S20

검증일: 2026-10-03 · 수정 기준: `45b1e5894667537bfa2c0797be8a33af9c4965a7` · 정식 버전 1.24.1 유지

- 최종 통합 검토의 F1–F6와 M2를 로컬 `7dfc394781708ccc0362d3da97fd0331fce287de`에서 처리하고 독립 재검토로 확인했습니다. 작은 검증 receipt·명시적 원문 읽기, generation당 audit 1회와 기존 selected-read 검사, 완결 generation CSV, 독립 비교 모델 체크박스·제외 건수, 잠자기 일시 중단, 짧은 공식 세션의 제외 분모를 다룹니다. 기존 손상 전체-list/write/resume 정책과 native 저장 검증은 유지합니다.
- 공개 fixture의 Swift backtest/evaluation와 네이티브 화면 밖 렌더, Node 및 실제 설정 페이지의 모의 IPC 검사 근거는 `.superpowers/sdd/2026-10-02-stock-forecast-evaluation/final-fix-report.md`에 보존합니다. Rust 소스/IPC는 변경하지 않으며 S19의 검사 결과를 재사용합니다. 이 기록은 공급자 성능·모델 순위·실제 Windows 실행·physical suspend의 증거가 아닙니다.
- Windows의 5초 초과 checkpoint 간격 감지는 느린 요청도 중단할 수 있으며 짧은 suspend는 놓칠 수 있습니다. 사용자 Resume가 필요합니다. 초기 조회에 대한 후속 B1 검토는 아래의 좁은 수정 범위만 대상으로 수행했습니다.

- 독립 재검토에서 새 잠자기 observer가 유휴 상태의 초기 저장 목록 조회를 무효화하는 B1을 확인했습니다. 로컬 `7914244c3568b372f94472a2cddf73bcc455e28a`에서 유휴 취소를 무시하고 읽기 전용 초기 목록을 현재 상태와 병합합니다. 현재 ID의 최신 상태가 우선하며 이전의 미발견 ID도 유지합니다. 기존 아카이브 검사와 실행 중 취소·쓰기 검증은 그대로입니다. 해당 bootstrap 범위의 재검토에서 B1 해결과 새 문제 없음을 확인했습니다.
- 최종 보완의 집중 Swift 검사는 **고유 51개**, 최신 Node 검사는 서로 다른 두 실행의 **51개 + 9개 = 60개**가 통과했습니다. 실제 설정 페이지의 모의 IPC 검사는 EN/KO 24개 배치와 지연 읽기·선택 비교·CSV 경계를 통과했습니다. B1 후속은 **관련 6개 통과**이고 테스트 종료 정리만 변경한 뒤 그 1개를 재확인했습니다. 서로 겹치는 실행 건수를 합산하거나 새 전체 Swift 통과로 표현하지 않습니다. 명령·로그·해시·종료 코드는 로컬 `final-fix-report.md`, `b1-fix-report.md`, `final-rereview.md`, `b1-rereview.md`에 보존합니다.
- 필수 구현·오프라인 검증·검토를 수락했고 결과는 `codex/stock-forecast-evaluation`의 로컬 개발 브랜치에 남깁니다. 선택적 실제 제공처 과거 조회는 미수행이므로 실제 확보율이나 모델 순위를 결론내리지 않습니다. 개인 이력·연구 파일·원본 main·설치본을 변경하거나 GitHub에 게시하지 않았습니다.


## S21

### 2026-10-03 1.25.0 정식 릴리즈

- 고정 소스: [`8d5b35e0fa3b8b70cc8c257d740b007e4e88a820`](https://github.com/pmh10401/PenguinNotch/commit/8d5b35e0fa3b8b70cc8c257d740b007e4e88a820), [v1.25.0](https://github.com/pmh10401/PenguinNotch/releases/tag/v1.25.0). **macOS 1.25.0/build 66·Windows 1.25.0/r58**이며 2026-10-03 00:22:46 UTC에 정식 공개했습니다. 통합 예측 기록·평가, 20/60/120거래일의 일봉·1분봉·10분봉 재현과 원본 근거·CSV를 포함합니다. S18–S20의 당시 미배포·실패 기록은 보존합니다.
- [최종 macOS CI](https://github.com/pmh10401/PenguinNotch/actions/runs/37080679514): **2,265개 중 선택적 13개 skip·실패 0**, SwiftPM 고정 의존성 확인 통과입니다. 공개 EN/KO 세 화면씩의 실제 네이티브 렌더도 통과했습니다. 앞선 CI OCR 오인식은 [변경 기록](log.md)에 남겼으며, 영어 경고의 `i/l` 일치 판단만 정규화합니다. 전체 경고·부정어, 모델 식별자, 픽셀·위치·접힘 검사는 유지하며 OCR로 정확한 영어 철자를 증명했다고 주장하지 않습니다.
- [Windows CI](https://github.com/pmh10401/PenguinNotch/actions/runs/37073250698): **246개 통과·선택적 4개 제외·실패 0**, Clippy와 실제 Chromium의 영어·한국어 모의 IPC 검사가 통과했습니다. 검사 소스는 `65fd6e5`이며 이후 태그까지 Windows 제품·테스트·의존성/패키지 구성은 바뀌지 않았습니다. 이 근거를 새 동일 소스 재실행으로 표현하거나 로컬과 합산하지 않습니다.
- [최종 macOS 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/37080679461)와 [초기 Windows 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/37073250570)가 성공했습니다. 공개 DMG는 이미 업데이트 서명한 `3eba02a` 빌드이며 최종 `8d5b35e` 앱과 **90개 파일·링크·파일 모드가 모두 일치**합니다. 변경은 테스트·CI 진단·위키뿐이며 추가 키체인 읽기 없이 서명된 동일 앱을 사용합니다. DMG 내부 버전/build, arm64·x86_64, 엄격한 코드 서명과 디버그 권한 부재를 확인했습니다.
- [릴리즈 후 Windows 배포](https://github.com/pmh10401/PenguinNotch/actions/runs/37081819946)는 태그의 같은 `8d5b35e`에서 **NSIS 설치·doctor·제거·설치 파일 게시·서명 피드 게시를 모두 통과**했습니다. 최종 EXE/피드를 공개 최신 주소에서 다시 받아 초기 패키지 자산과 섞지 않고 검증했습니다.
- 공개 키로 Sparkle Ed25519와 Tauri Minisign 설치 파일 서명 및 변조 거부를 확인했습니다. Sparkle은 DMG enclosure를 서명하며 XML 자체의 분리 서명이 있다고 주장하지 않습니다. 두 피드는 버전별 `v1.25.0` 파일을 가리키며 `releases/latest/download/`의 다섯 파일은 모두 **HTTP 200·GitHub SHA-256 일치**입니다. 최종 Windows 파일에 맞춰 [SHA256SUMS.txt](https://github.com/pmh10401/PenguinNotch/releases/download/v1.25.0/SHA256SUMS.txt)를 갱신했고 목록 자체의 SHA-256은 `d11b161151757a64cdb5642327df7f7e72b1c6bbdfaa057b8b59ef9a4c481e37`입니다.
- 한계: 공개 Mac은 임시 서명·**Apple 공증 미적용**, Windows는 **Authenticode 미적용**입니다. 업데이트 서명과 OS 첫 설치 경고는 별개입니다. 실제 제공처의 과거 확보율·모델 성능·주문 수익, 실계좌 대조·사용자 Windows 실기·physical suspend는 검증하지 않았습니다. 현재 조회한 수정 데이터 재현을 당시 가용 정보로 보장하지 않으며 모델을 자동 채택하지 않습니다. Codex 수동 실행은 macOS 전용입니다. 기존 이력·연구 자료와 이 Mac의 1.24.1 설치본은 보존합니다.
- 최종 파일 SHA-256: DMG `c0be38d8d41be521afcbce2090d6fc8f9c4c3b7f8746dcad317502f5af05add5`, appcast `c4c16befcca6ed7de1d37667766cd848fe5ddf0ae1ce1e96addb8e8edad03bdf`, EXE `831c4e2c4a941f29f7d117251638ac5dc7a5d8363a410ffe7b6912e53b5a8c54`, latest.json `68dc7e75983c98978612fcc24c04fc38cec3a07e74a46749e98bfd415a10f74b`.

## S22

- 검증일: 2026-10-03 KST · 소스: `86c2dfa` 이후 로컬 1.25.1/macOS build67/Windows r59 개발 변경. 아직 정식 배포·설치본 교체·실제 계정 호출은 없습니다.
- [토스 인증 구현](../../Sources/Widgets/TossInvestClient.swift), [키체인 원시 결과/쓰기](../../Sources/Providers/KeychainItem.swift), [상호작용 제어](../../Sources/Providers/KeychainPrompt.swift), [공통 캐시](../../Sources/Providers/CredentialCache.swift), [설정의 명시적 접근 허용](../../Sources/Settings/StockSettings.swift), [토스 오프라인 검사](../../Tests/TossCredentialsTests.swift), [캐시 검사](../../Tests/AntigravityTests.swift).
- 같은 두 동시 요청과 진행 중 삭제 사례를 수정 전 테스트에서 재현했습니다. 기존 분리 저장 동작을 사용한 오프라인 fixture에서도 단일 읽기·원자적 쌍 저장·거부/손상 보존·명시적 허용 검사가 수정 전 실패했습니다. 변경 후 관련 29개 검사가 통과했습니다. 실제 사용자 키체인의 데이터는 조회하거나 내보내지 않았으며 새로운 보존 검사는 주입한 네이티브 연산만 대체합니다.
- macOS 전체 재검사는 **2,276개·8개 건너뜀·실패 0개**로 통과했습니다. 최초 전체 검사에서는 `StockCodexRunnerTests.testTimeoutKillsProcessGroupAndUnblocksWrites`가 테스트용 프로세스의 준비 파일을 읽지 못해 1개 실패했습니다. 해당 코드와 검사를 변경하지 않고 단독 재검사(9개·1개 건너뜀·실패 0개) 및 전체 재검사가 통과했으며, 최초 실패의 원인을 확정한 것으로 표현하지 않습니다. Grok의 읽기 전용 최종 검토에는 수정이 필요한 지적이 없었습니다. 로컬 로그·소스 해시는 `build/keychain-1.25.1-20261003/verification.json`에 기록합니다.
- Windows는 제공자별 단일 Credential Manager blob을 이미 사용합니다. 변경은 버전 표기뿐이며 `node windows/scripts/test-stocks.cjs`가 통과했습니다. 실제 Windows Credential Manager와 WebView2 사용자 조작은 이번에 실행하지 않습니다.
- 설치된 1.25.0/build66은 `Signature=adhoc`, `TeamIdentifier=not set`, `designated => cdhash …`입니다. 인증서 조회는 Developer ID Application 유무와 Apple Development 유무만 기록합니다. 사용자/인증서 이름·비밀·계좌는 문서에 넣지 않습니다.
- [Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)의 Keychain Access Controls 및 Code Designated Requirement 설명을 근거로 서명 신원의 유지와 인증 정보 묶음을 구분합니다. 실제 네 번의 창 이름과 OS 승인 수는 미확인입니다. 최초 이전 및 다른 서비스는 별도 승인이 남을 수 있고 Sparkle 빌드 도구의 서명 승인 횟수를 줄인 변경은 아닙니다.

## S23

- 검증일: 2026-10-03 KST · 정식 [v1.25.1](https://github.com/pmh10401/PenguinNotch/releases/tag/v1.25.1) · 소스 [`320787528290c9e4d56468af28f5a0ef5f445e62`](https://github.com/pmh10401/PenguinNotch/commit/320787528290c9e4d56468af28f5a0ef5f445e62) · macOS build67 / Windows r59. S22의 로컬 검증 및 실제 OS 승인 횟수 미확인은 보존합니다.
- [macOS CI](https://github.com/pmh10401/PenguinNotch/actions/runs/37122615243)는 **2,276개·13개 건너뜀·실패 0개**, [Windows CI](https://github.com/pmh10401/PenguinNotch/actions/runs/37122615211)는 **246개 통과·4개 제외·실패 0개**입니다. Windows 실제 HTML의 영어·한국어 설정 24개, 네 방향 원/막대 노치 48개 배치와 업데이트 카드 검사는 공개 모의 IPC로 실행됐으며 물리적 사용자 기기 검증과 구분합니다.
- [macOS 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/37122615276)는 해당 소스의 범용 DMG를 생성했습니다. arm64/x86_64, macOS 15 이상, ad-hoc 서명, 깊은 서명 검증 통과, get-task-allow 없음과 실제 Release 바이너리의 오프라인 테스트 호스트 실행을 확인했습니다. 정상 앱은 이 Mac의 `/Applications/PenguinNotch.app`에 1.25.1/build67로 설치해 프로세스 경로를 확인했습니다. 기존 1.25.0 앱은 로컬 `build/release-1.25.1-20261003/rollback/`에 복구용으로 보관하며 설정·주식 기록·키체인 항목을 삭제하지 않았습니다.
- [초기 Windows 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/37122615200)와 [릴리즈 후 Windows 패키지](https://github.com/pmh10401/PenguinNotch/actions/runs/37125517198)는 같은 `3207875`에서 설치·doctor·제거·서명 피드 생성을 통과했습니다. 후속 작업의 설치 파일·피드 게시까지 확인한 뒤 최종 공개 바이트를 다시 받아 해시 목록을 갱신했습니다. 초기 파일과 검증 기록은 별도 로컬 폴더로 보존합니다.
- Sparkle의 DMG enclosure Ed25519 서명과 Tauri의 Windows 설치 파일 Minisign 서명을 공개 키로 검증하고 변조 바이트의 거부를 확인했습니다. XML 자체의 분리 서명을 주장하지 않습니다. 두 피드는 버전별 `v1.25.1` 설치 파일을 가리키며 `releases/latest/download/`의 두 설치 파일·두 피드·[SHA256SUMS.txt](https://github.com/pmh10401/PenguinNotch/releases/download/v1.25.1/SHA256SUMS.txt)는 모두 **HTTP 200·GitHub SHA-256 일치**입니다.
- 최초 appcast 생성은 검증용 DMG가 이미 마운트되어 추출에 실패했습니다. 해당 마운트만 해제한 뒤 동일 DMG로 재시도해 성공했습니다. 승인된 기존 Sparkle 키를 도구 내부에서 사용했으며 개인 키를 내보내거나 키체인 ACL을 바꾸지 않았습니다. 로컬 상세 로그·소스/파일 해시·설치 결과는 `build/release-1.25.1-20261003/verification.json`에 보관합니다.
- 한계: Mac 공개/설치 앱은 **Apple 공증 미적용**, Windows는 **Authenticode 미적용**입니다. 업데이트 서명과 OS 설치 경고는 별개입니다. 실제 암호 창이 정확히 1회라는 검증, 실제 계좌 대조, 사용자 Windows의 센서·다중 모니터·키체인/자격 증명 검증은 수행하지 않았습니다. Sparkle 빌드 도구의 서명 승인은 주식 자동 조회의 키체인 접근과 별도입니다.
- 최종 SHA-256: PenguinNotch.dmg `0b9c073a3593684ac22e44d5de2b1de81641fc00293db0101dcfe397e4950840`, appcast.xml `5ea8de1d48f95674ef070dfb3b9fafab09ef49cc129b6e35d68fb34e385c5a62`, PenguinNotch-Setup.exe `dfbe6f3207eaf4b9457082afdabe29685d4d702423cb543dbdb9db040feb4b9f`, latest.json `0583eebda639171effd8e5d4f8b14d91632aa78e93272d7feed61582d424d1f3`, SHA256SUMS.txt `aa1dbc73c2631d8466e766f871487ef7ed3e3f6427072cda43af8f1f08b41637`.


## S24

### 2026-10-04 1.26.0 개발 소스의 외장 볼륨 표시

- 기준 커밋: `65934fc12278ea0d06f3d2cada1757ca10284e21` 이후 로컬 `codex/external-disk-monitoring` 작업 트리. **macOS 1.26.0/build68 · Windows 1.26.0/r60**으로 버전을 올렸으며, 설치·커밋·푸시·정식 릴리즈·원격 CI는 수행하지 않았습니다. 정식 배포는 S23의 1.25.1입니다.
- macOS는 홈 볼륨만 읽던 경로에 추가 로컬 마운트 볼륨을 전달합니다. UUID/루트 중복·홈 볼륨 제외, 알 수 없는/잘못된 용량과 네트워크 제외, 합산 없는 볼륨별 표시, 단일 별도 조회·30초 캐시·마운트/해제/이름/복귀 세대 무효화, 호버 높이와 스크롤을 구현했습니다. 추가 디스크 때문에 홈 대표 원의 분모를 바꾸지 않습니다.
- RED: 실제 읽기 가능한 추가 볼륨이 있는 이 Mac에서 기존 호버가 추가 높이를 할당하지 않는 검사가 **1개 실패**했습니다. 구현 후 모니터링·디스크·호버/배치/스크롤·언어 회귀 **89개 중 선택적 1개 skip·실패0**입니다. 이후 테스트만 보강한 영어/한국어 렌더·볼륨 경계·캐시·실제 마운트 경로 전달 검사 **7개 실패0**을 별도로 기록하며 서로 중복된 분모를 합산하지 않습니다.
- 실제 연결된 추가 로컬 볼륨 1개의 유효 용량과 앱 호버 데이터로의 전달을 확인했습니다. 실제 이름·경로·UUID·기기 정보는 이 위키에 저장하지 않습니다. 실제 장치 분리/재연결·잠금 해제·네트워크 저장소는 검사하지 않았습니다. 잠긴·미마운트 장치를 자동으로 마운트/포맷/해제하지 않습니다.
- Windows 기존 볼륨 열거·가중 합산은 유지합니다. 로컬 Mac의 `system_usage::disk_tests` **2개 실패0**, Windows GNU 전체 대상 교차 컴파일 통과, Node 위젯·한국어 8개·UI 문법 검사 통과입니다. 기존 실제 Chromium 스크롤/조작 검사와 추가 **EN/KO × 네 가장자리 × 원/막대 16개** 외장 볼륨 카드 검사(이스케이프·휠 마지막 행·분리 목록 제거)가 통과했습니다. Win32 기기 조회·WebView2·실제 Windows USB 장치 런타임 검증은 수행하지 않았습니다.
- 처음 추가한 언어 렌더 테스트는 공용 언어 설정에 쓰는 경로를 사용해 언어 선택을 시스템 자동으로 초기화했습니다. 해당 테스트를 `L10n.testLocale` 임시 주입/원상 복귀 방식으로 수정해 사용자 설정에 쓰지 않도록 했습니다. 원래 사용자 언어 값은 확인할 수 없어 별도 복구 선택을 요청했습니다. 카탈로그는 EN/KO 키 1개만 추가했고 기존 모든 항목을 동일하게 보존했습니다.
- README 두 언어와 Windows README에 실제 볼륨/캐시 동작을 반영하고 개발/정식 배포 경계를 구분합니다. 과거 Windows “30초 조회” 문구는 실제 1초 샘플 루프의 단일 별도 조회와 달라 수정했습니다.
- Grok의 공개 소스 최종 검토에서 실제 호스트 테스트가 UUID 별칭·APFS System/Data 루트를 중복 요구할 수 있다는 테스트 문제 1개를 지적했습니다. OS가 외장으로 식별한 볼륨의 UUID 집합으로 검증하도록 보완했고 실제 호스트 단독 검사 1개가 실패 없이 통과했습니다. 앱 제품 코드 지적은 없었습니다.
- 주요 코드/검사 파일 SHA-256 (로컬 검증 시점):
  - `Sources/System/SystemDiskVolumes.swift`: `699e38a5cd4a2756b04da098ef9f773b231d2995f3c494517aa730f623ebc25a`
  - `Sources/System/SystemUsageSampler.swift`: `817b6ec3aba74e7ac89b89403e0d86b7b162e048f1ca1f1344af4e20f5b18dde`
  - `Sources/System/SystemUsageMonitor.swift`: `ad3f55d1f2c1a74a738c9691e06f87f1713c0a60cbe82edfbfd59c485b96a70c`
  - `Sources/Features/TooltipCard.swift`: `ef440d929922fe9ce433780cd112de837077f05bd6a392f1816988cb80693d38`
  - `Sources/Model/UsageModel.swift`: `ed675d2bd61ab9f1df79e5633126430bbb79cbf0cf3ccc34d4fb707efcfa09b3`
  - `Sources/Notch/NotchLayout.swift`: `30f32774b3a84255fe0199f308e04f5876bc2d155cf476ed1c98b56601bd67a0`
  - `Sources/Notch/NotchViewModel.swift`: `31362b9da52590e92a25d36164a90b353ace8e4e59e9f54ef8549658aa082d00`
  - `Tests/SystemDiskTests.swift`: `ac68de43b11c61f2a1fb81afdeef203eb1d661f1bd74501ec8a5583585a72564`
  - `Tests/SystemUsageTests.swift`: `a18f460e8b27824246ad4b6860a38e9358ab3b04a9538163ee3734282618aec2`
  - `windows/scripts/test-notch-scroll-browser.cjs`: `8f7981b857c1c4af9f8e21cd09fc2236d23f31d5637a30b9cf4cb54e25c7f006`

재현 명령(저장소 루트; Xcode/고정 의존성과 기존 Playwright 필요):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make gen
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PenguinNotch.xcodeproj -scheme PenguinNotch -destination 'platform=macOS,arch=arm64' -configuration Debug -only-testing:PenguinNotchTests/SystemDiskTests -only-testing:PenguinNotchTests/SystemUsageTests -only-testing:PenguinNotchTests/SystemUsageIntegrationTests CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test
cargo test --manifest-path windows/Cargo.toml -p penguinnotch --locked --features tauri/macos-private-api system_usage::disk_tests::
cargo check --manifest-path windows/Cargo.toml --locked --offline --workspace --all-targets --target x86_64-pc-windows-gnu
node windows/scripts/test-widgets.cjs
node windows/scripts/test-ko-i18n.cjs
node windows/scripts/check-ui-scripts.mjs
node windows/scripts/test-notch-scroll-browser.cjs
```

macOS 호스팅 Rust 테스트의 `tauri/macos-private-api`는 Mac 빌드에만 필요합니다. 실제 Windows에서는 이 기능 없이 네이티브 테스트를 수행합니다. 위 교차 컴파일에는 설치된 GNU 대상/링커가 필요합니다. 실제 장치가 없으면 Mac의 추가 볼륨 검사는 skip됩니다.
