# 프로젝트 목표와 코드 위치

검증일: 2026-09-28 · 기준: [S2](sources.md#s2), 커밋 `b7b1b69`.

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

## 유지할 경계

- macOS와 Windows의 사용자 경험은 최대한 맞추되, 네이티브 저장소·센서·업데이트 구현은 다릅니다. 한 플랫폼에서 통과한 테스트만으로 다른 플랫폼 검증을 대신하지 않습니다. [S2](sources.md#s2) · [검증 범위](maintenance.md)
- 공급자가 제공한 값, 계산한 값, 알 수 없는 값을 구분합니다. 누락된 시세·센서값을 0이나 추정 시각으로 채우지 않습니다. [S2](sources.md#s2) · [S4](sources.md#s4)
- 개발 위키의 문장은 앱에 자동으로 입력되지 않습니다. 별도 모델 연구나 뉴스 분석을 실제 예측에 연결하려면 입력·모델·시점을 고정한 검증이 필요합니다. 현재 앱 모델은 [주식 페이지](stocks.md)에 정리합니다.

다음 작업의 출발점은 [색인](index.md), 과거 변경의 확인은 [이력](log.md)입니다.
