<p align="center">
  <img src=".github/assets/token-jar-banner.jpg" alt="Token Jar — Your AI limits. One quiet place." width="100%">
</p>

<p align="center">
  <strong>AI 사용량은 한곳에. 집중은 하던 일에.</strong><br>
  Codex · Claude · Grok · Cursor · Doubao를 위한 가벼운 macOS 메뉴 막대 앱
</p>

<p align="center">
  <a href="https://github.com/nahwan-kim/token-jar/actions/workflows/ci.yml"><img src="https://github.com/nahwan-kim/token-jar/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-173F35" alt="macOS 14 이상">
  <img src="https://img.shields.io/badge/Swift-6-F05138" alt="Swift 6">
  <img src="https://img.shields.io/badge/languages-한국어%20%2F%20English-00856F" alt="한국어 및 영어 지원">
</p>

<p align="center">
  <a href="#시작하기">시작하기</a> ·
  <a href="#지원하는-서비스">지원 서비스</a> ·
  <a href="#소스에서-빌드">직접 빌드</a> ·
  <a href="#개발과-기여">기여하기</a>
</p>

---

## 적게 열고, 한눈에 확인하세요

토큰 항아리(Token Jar)는 여러 AI 도구의 사용량과 한도, 초기화 시점을 한곳에 모읍니다. 서비스마다 대시보드를 열거나 계정을 번갈아 확인할 필요 없이, 메뉴 막대에서 상태를 보고 별도 사용량 창에서 자세히 살펴보세요.

- **메뉴 막대에 필요한 숫자만** — 서비스 표시 여부, 순서, 약어, 대표 한도를 설정합니다.
- **서비스가 제공한 값 그대로** — 사용량·잔여량의 방향을 구분하고, 제공되지 않은 값은 추정하지 않습니다.
- **Codex 계정별 확인** — 기본 계정과 선택적인 두 번째 `CODEX_HOME`의 한도를 따로 표시합니다.
- **자동 갱신과 수동 새로고침** — 5분 간격으로 갱신하며, 실패하면 앱 실행 중 마지막 성공 값과 오류 상태를 구분합니다.
- **한국어와 English** — 설정에서 바로 전환합니다.
- **네이티브 macOS 앱** — SwiftUI 기반. Dock 아이콘과 내장 브라우저 없이 동작하며, 새 버전을 확인해 공식 다운로드 페이지로 안내합니다.

## 시작하기

**요구 사항:** macOS 14 Sonoma 이상, 사용할 서비스의 공식 앱 또는 CLI와 유효한 로그인 세션.

[GitHub Releases](https://github.com/nahwan-kim/token-jar/releases)에서 **미공증 프리릴리즈** ZIP을 받을 수 있습니다. Apple Silicon과 Intel을 함께 지원하는 Universal 빌드이며, **Developer ID 서명과 Apple 공증 없이 ad-hoc 서명으로 배포**합니다. Apple이 개발자 신원이나 앱을 확인한 배포물이 아닙니다.

1. 릴리즈의 ZIP과 `SHA256SUMS`를 내려받고, 터미널에서 `shasum -a 256 -c SHA256SUMS`로 무결성을 확인합니다.
2. ZIP을 풀고 `Token Jar.app`을 Applications 폴더로 옮깁니다.
3. 처음 실행할 때 차단되면 출처와 체크섬을 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**에서 이 앱만 허용합니다. 회사 관리 정책이나 macOS 버전에 따라 허용되지 않을 수 있습니다. 악성 소프트웨어 경고가 나오면 실행하지 마세요.

Gatekeeper 전체 비활성화나 quarantine 속성 제거는 필요하지 않습니다. 체크섬은 다운로드 무결성 확인용이며 개발자 신원 인증을 대신하지 않습니다. 새 버전은 자동으로 확인하며 설정에서 자동 확인을 끄거나 직접 확인할 수 있습니다. 알림의 공식 GitHub 릴리즈 링크에서 ZIP을 내려받아 수동 교체하세요. **자동 다운로드·설치는 하지 않습니다.** Homebrew 패키지는 제공하지 않으며, 이전 버전은 교체 검증이 끝날 때까지 보관하세요.

초기 프리릴리즈는 모든 서비스의 최종 라이브 검증, Intel 실기기 및 깨끗한 macOS 14 호스트 검증을 완료했다는 뜻이 아닙니다. 버전별 검증 범위와 알려진 제한은 릴리즈 노트를 확인하세요.

1. 사용할 서비스의 공식 앱이나 CLI에 먼저 로그인합니다.
2. Token Jar를 실행하고 메뉴 막대에서 사용량 창을 엽니다.
3. 설정에서 표시할 서비스와 대표 한도를 선택합니다.

Token Jar 자체 계정은 필요하지 않습니다. 세션이 만료되면 해당 서비스의 공식 앱이나 CLI에서 다시 로그인하세요.

## 지원하는 서비스

| 서비스 | 읽는 데이터 | 준비 사항 |
| --- | --- | --- |
| **Codex** | 공식 `codex app-server`의 구독 사용량 한도 | Codex CLI 로그인. 기본 `~/.codex`, 선택적으로 `~/.codex-secondary` |
| **Claude** | `~/.claude.json`의 `cachedUsageUtilization` | Claude Code가 기록한 사용량 캐시 |
| **Grok** | Grok CLI 세션으로 조회한 SuperGrok 크레딧 | Grok CLI 로그인 및 `~/.grok/auth.json` |
| **Cursor** | Cursor 로컬 세션으로 조회한 계정 사용량 요약 | Cursor 앱 로그인 |
| **Doubao** | 공식 `arkcli usage plan --format json`의 플랜 한도 | `arkcli` 설치 및 유효한 SSO 로그인 |

> **연동 범위에 주의하세요.** 모든 서비스가 안정적인 공개 사용량 API를 제공하지는 않습니다. Claude의 로컬 캐시와 Grok·Cursor의 연동은 제공자 변경에 영향을 받을 수 있습니다. 캐시가 오래됐거나 세션·응답 형식이 달라지면 데이터를 만들거나 다른 출처로 대체하지 않고 오류를 표시합니다. API 과금 전체를 합산하는 비용 관리 도구는 아닙니다.

정확한 경로, 조회 방식, 알려진 제한과 검증 상태는 [ProviderSources.json](TokenTankApp/Distribution/ProviderSources.json)에 기록되어 있습니다.

## 내 계정은 원래 있던 곳에

- 공식 도구가 소유한 인증 저장소를 수정하거나, 인증 정보를 별도 파일로 복사·저장·갱신하지 않습니다.
- Grok·Cursor 조회에 필요한 기존 세션은 메모리에서 사용합니다. 브라우저 쿠키를 가져오지 않습니다.
- 사용량 스냅샷은 메모리에만 유지합니다. 표시 설정은 로컬에 저장합니다.
- Codex와 Doubao는 허용된 공식 CLI를 실행합니다. 공식 CLI 자체의 세션 관리는 해당 도구가 담당합니다.
- 네트워크 조회가 필요한 서비스는 해당 제공자에 직접 요청합니다. 완전한 오프라인 앱은 아닙니다.
- 새 버전 확인은 GitHub 공개 API에 요청합니다. 계정·사용량·인증 정보를 보내지 않지만 GitHub에는 IP 주소 등 연결 정보가 전달됩니다. 자동 확인 설정과 마지막 확인 시각은 로컬에 저장합니다.

세부 보안 경계와 배포 전 검토 항목은 [SecurityReview.md](TokenTankApp/Distribution/SecurityReview.md)를 참고하세요. 이 문서는 검토 기록과 체크리스트이며, 독립 보안 감사 인증을 의미하지 않습니다.

## 소스에서 빌드

Xcode 16.2 이상과 Swift 6 도구 체인이 필요합니다.

```sh
git clone https://github.com/nahwan-kim/token-jar.git
cd token-jar
open TokenTank.xcodeproj
```

Xcode에서 **TokenTank** scheme과 **My Mac**을 선택하고, 앱 타깃의 **Signing & Capabilities → Team**을 본인의 개발 팀으로 변경한 뒤 실행합니다. 프로젝트에 들어 있는 팀 ID는 기여자의 서명 설정이 아닙니다.

서명 없이 컴파일만 확인하려면:

```sh
xcodebuild \
  -project TokenTank.xcodeproj \
  -scheme TokenTank \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/token-jar-build \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build
```

결과는 `/tmp/token-jar-build/Build/Products/Release/Token Jar.app`입니다. **이 명령은 배포용 서명·공증을 수행하지 않습니다.** 공개 배포 절차는 [Distribution.md](TokenTankApp/Distribution/Distribution.md)를 따릅니다. Gatekeeper나 시스템 보안 기능을 끄는 설치 방법은 제공하지 않습니다.

## 개발과 기여

```sh
# Core 및 서비스 어댑터 테스트
swift test --package-path Packages/TokenTankCore

# 서비스별 파일·프로세스·네트워크 접근 경계 검사
bash Scripts/audit-provider-io.sh
```

앱 및 UI 테스트는 Xcode의 **Product → Test**에서 실행합니다. CI의 전체 검사 정의는 [ci.yml](.github/workflows/ci.yml)에 있습니다.

```text
TokenTankApp/            SwiftUI 앱, 설정, 리소스
Packages/TokenTankCore/  도메인 모델, 수집 런타임, 서비스 어댑터와 테스트
TokenTankTests/         앱 모델 테스트
TokenTankUITests/       UI 및 접근성 테스트
Scripts/               접근 경계 검사와 유휴 성능 측정
```

버그 제보에는 macOS·앱·공식 CLI 버전과 재현 순서를 적어 주세요. **토큰, 쿠키, 이메일 주소, 실제 인증 파일과 원본 API 응답은 올리지 마세요.** 서비스 연동 변경에는 개인정보를 제거한 fixture와 실패 상황 테스트를 함께 추가해 주세요.

## About

Token Jar is a native macOS menu bar app for checking AI usage limits across Codex, Claude, Grok, Cursor, and Doubao. It keeps provider-specific quotas separate, supports English and Korean, and uses existing official app or CLI sessions rather than introducing another account.

Provider names and logos belong to their respective owners. Token Jar is an independent project and is not endorsed by those providers. [CodexBar](https://github.com/steipete/CodexBar) is referenced for provider integration behavior; it is not a runtime dependency. The README banner was generated with GPT Image 2 through ima2 using the app icon as a visual reference.

## 라이선스

[MIT License](LICENSE). 자유롭게 사용·수정·재배포할 수 있습니다. 포함된 브랜드 아이콘의 라이선스와 상표 고지는 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)를 참고하세요.
