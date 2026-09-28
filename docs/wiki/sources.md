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
