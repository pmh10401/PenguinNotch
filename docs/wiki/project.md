# 프로젝트 목표와 코드 위치

검증일: 2026-09-28 UTC · 기본 기준: [S2](sources.md#s2), 커밋 `b7b1b69` · Windows 설정 변경: [S8](sources.md#s8)의 1.20.5 작업 트리. 원본 통합: 2026-09-29 KST, [S9](sources.md#s9)의 1.21.0 소스.

## 현재 목표

PenguinNotch는 macOS와 Windows의 화면 가장자리에서 AI 구독 사용량, 컴퓨터 상태, 주식 시세·기술적 분석, 생활 위젯을 확인하는 앱입니다. 항목을 숨기거나 재정렬하고, 호버에서 상세 내용을 확인합니다. 주식 분석은 근거와 나중에 확인한 결과를 보존하며 주문은 실행하지 않습니다. 예측 정확도는 별도로 평가해야 합니다. [S2](sources.md#s2) · [주식 규칙](stocks.md)

## 작업할 위치

| 관심사 | macOS | Windows |
| --- | --- | --- |
| 노치 표시·입력 | `Sources/Notch/` | `windows/penguinnotch/ui/notch.html`, `src/main.rs` |
| 설정 | `Sources/Settings/` | `windows/penguinnotch/ui/settings.html` |
| 구독 사용량 | `Sources/Providers/`, `Sources/Model/` | `windows/penguinnotch/src/`의 제공자 모듈 |
| 주식 | `Sources/Widgets/Stock*.swift`, `TossInvestClient.swift` | `windows/penguinnotch/ui/stocks.js`, `src/stocks.rs` |
| 검증 | `Tests/`, `make test-ci` | `windows/scripts/`, `cargo test --locked` |

Windows 표의 `src/` 경로는 `windows/penguinnotch/` 아래입니다. 구체적인 사용법은 [영문 README](../../README.md), [한국어 README](../../README.ko.md), [Windows README](../../windows/README.md)를 참고합니다. 위키는 그 문서를 복제하기보다 동작을 바꾸기 전에 알아야 할 규칙을 연결합니다. [S2](sources.md#s2)

## Windows 설정 분류

1.20.5 소스에서는 macOS와 같은 순서로 **AI 구독 → 주식 → 컴퓨터 모니터링 → 생활 위젯 → 모양 → 일반**을 표시합니다. Windows에서 구현된 기능만 분류하며, macOS 전용 서비스·알림 페이지는 추가하지 않습니다. 주간 사용량 원은 AI 구독에, 언어·트레이 아이콘은 일반에 있습니다. 하드웨어와 생활 위젯은 각각의 페이지에서 표시·색상·순서를 바꿉니다. [S8](sources.md#s8)

저장 스키마와 IPC는 유지합니다. 한 분류의 순서를 바꾸면 그 분류의 기존 위치만 교환합니다. 과거의 생활 위젯 활성화 값과 숨김 값이 충돌하면 실제 표시 여부를 스위치에 반영하고, 사용자가 켤 때 해당 항목의 숨김을 해제합니다. 저장 중에는 중복 변경을 막고 실패하면 기존 값을 보존합니다.

`node windows/scripts/test-settings-browser.cjs`로 실제 HTML과 가짜 네이티브 응답을 함께 검사합니다. 설치된 Playwright가 필요합니다. 한글·영문, 키보드 이동, 마지막 탭 복원, 분류별 저장·순서 보존, 날씨 검색, 저장 실패, 주식 탭 가시성 이벤트 및 밝음·어두움/두 창 크기의 24개 배치 검사가 통과했습니다. UI 문법과 기존 주식·위젯·인증·한국어 회귀 검사도 통과했습니다. **실제 Windows WebView2와 네이티브 설치본은 이번 작업에서 검사하지 않았으며 1.20.5는 아직 공개 릴리즈가 아닙니다.** [S8](sources.md#s8)

## 원본과의 통합

CodeNotch `0083369`(1.19.0)까지의 변경은 1.21.0에 통합합니다. macOS의 여섯 점 이동 손잡이·카메라 옆 배치·노치 업데이트 안내, Kilo·Apify와 주간 한도 대표 표시를 추가하며, Windows는 OpenCode Go·시스템 프록시·표면·최상위 창 처리를 반영합니다. 기존 주식·모니터링·생활 위젯·휠 스크롤·순서와 설정 분류를 보존합니다. PenguinNotch의 이름·키체인 정책·업데이트 주소를 사용하며 원본의 설치 파일과 앱캐스트는 가져오지 않습니다. [S9](sources.md#s9)

## 유지할 경계

- macOS와 Windows의 사용자 경험은 최대한 맞추되, 네이티브 저장소·센서·업데이트 구현은 다릅니다. 한 플랫폼에서 통과한 테스트만으로 다른 플랫폼 검증을 대신하지 않습니다. [S2](sources.md#s2) · [검증 범위](maintenance.md)
- 공급자가 제공한 값, 계산한 값, 알 수 없는 값을 구분합니다. 누락된 시세·센서값을 0이나 추정 시각으로 채우지 않습니다. [S2](sources.md#s2) · [S4](sources.md#s4)
- 개발 위키의 문장은 앱에 자동으로 입력되지 않습니다. 별도 모델 연구나 뉴스 분석을 실제 예측에 연결하려면 입력·모델·시점을 고정한 검증이 필요합니다. 현재 앱 모델은 [주식 페이지](stocks.md)에 정리합니다.

다음 작업의 출발점은 [색인](index.md), 과거 변경의 확인은 [이력](log.md)입니다.
