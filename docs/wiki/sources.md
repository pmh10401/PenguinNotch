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
