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

- **메뉴 막대에 필요한 숫자만** — 서비스 표시 여부, 순서, 대표 한도를 설정합니다. ‘% 기호 표시’를 끄면 `63%` 대신 `63`으로 보이며, 상세 화면과 접근성 읽기의 퍼센트 정보는 유지합니다.
- **서비스가 제공한 값 그대로** — 사용량·잔여량의 방향을 구분하고, 제공되지 않은 값은 추정하지 않습니다.
- **Codex 계정별 확인** — 기본 계정과 선택적인 두 번째 `CODEX_HOME`의 한도를 따로 표시합니다.
- **자동 갱신과 수동 새로고침** — 5분 간격으로 각 출처를 다시 확인하며, 실패하면 앱 실행 중 마지막 성공 값과 오류 상태를 구분합니다. Claude 세션이 만료 직전이거나 사용량 요청에서 거부되면 Token Jar가 읽기 전용 저장소를 다시 확인하고, 필요할 때 Claude Code의 제한된 소유자 갱신을 자동으로 한 번 시도합니다.
- **한국어와 English** — 설정에서 바로 전환합니다.
- **로그인 시 자동 실행 선택** — 설정에서 ‘로그인 시 실행’을 직접 켜거나 끌 수 있습니다. macOS 승인이 필요하면 시스템 설정에서 허용하며, 기본값은 꺼짐입니다.
- **네이티브 macOS 앱** — SwiftUI 기반. Dock 아이콘과 내장 브라우저 없이 동작하며, Sparkle 업데이트 창에서 새 버전을 내려받아 설치·재시작할 수 있습니다.

## 시작하기

**요구 사항:** macOS 14 Sonoma 이상, 사용할 서비스의 공식 앱 또는 CLI와 유효한 로그인 세션.

[GitHub Releases](https://github.com/nahwan-kim/token-jar/releases)에서 **미공증 프리릴리즈** ZIP을 받을 수 있습니다. Apple Silicon과 Intel을 함께 지원하는 Universal 빌드이며, **Developer ID 서명과 Apple 공증 없이 ad-hoc 서명으로 배포**합니다. Apple이 개발자 신원이나 앱을 확인한 배포물이 아닙니다.

1. 릴리즈의 ZIP과 `SHA256SUMS`를 내려받고, 터미널에서 `shasum -a 256 -c SHA256SUMS`로 무결성을 확인합니다.
2. ZIP을 풀고 `Token Jar.app`을 Applications 폴더로 옮깁니다.
3. 처음 실행할 때 차단되면 출처와 체크섬을 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**에서 이 앱만 허용합니다. 회사 관리 정책이나 macOS 버전에 따라 허용되지 않을 수 있습니다. 악성 소프트웨어 경고가 나오면 실행하지 마세요.

Gatekeeper 전체 비활성화나 quarantine 속성 제거는 필요하지 않습니다. 체크섬은 다운로드 무결성 확인용이며 개발자 신원 인증을 대신하지 않습니다. 새 버전은 자동으로 확인하며 설정에서 자동 확인을 끄거나 직접 확인할 수 있습니다. **업데이트 창에서 승인하면 서명된 새 버전을 다운로드·설치하고 재시작합니다.** 자동 설치는 하지 않습니다. 기존 v0.1.3 이하 사용자는 앱 내 설치 기능이 포함된 버전을 한 번 수동 설치해야 합니다. Homebrew 패키지는 제공하지 않으며 이전 버전은 교체 검증이 끝날 때까지 보관하세요.

초기 프리릴리즈는 모든 서비스의 최종 라이브 검증, Intel 실기기 및 깨끗한 macOS 14 호스트 검증을 완료했다는 뜻이 아닙니다. 버전별 검증 범위와 알려진 제한은 릴리즈 노트를 확인하세요.

1. 사용할 서비스의 공식 앱이나 CLI에 먼저 로그인합니다.
2. Token Jar를 실행하고 메뉴 막대에서 사용량 창을 엽니다.
3. 설정에서 표시할 서비스와 대표 한도를 선택합니다.
4. 필요하면 설정의 ‘로그인 시 실행’을 켜고 macOS 시스템 설정에서 승인을 완료합니다. 이 옵션은 기본으로 꺼져 있습니다.

Token Jar 자체 계정은 필요하지 않습니다. Claude는 만료 직전 또는 HTTP 401인 Claude Code 세션을 자동 복구할 수 있습니다. 복구할 수 없거나 로그인이 없거나 폐기된 경우에는 `claude auth login`으로 Claude Code CLI에 다시 로그인해야 하며, 웹이나 Claude Desktop 로그인으로 대체되지 않습니다. Grok은 승인된 범위에서 만료 직전 OAuth 세션을 자동 갱신합니다.

## 지원하는 서비스

| 서비스 | 읽는 데이터 | 준비 사항 |
| --- | --- | --- |
| **Codex** | 공식 `codex app-server`의 구독 사용량 한도 | Codex CLI 로그인. 기본 `~/.codex`, 선택적으로 `~/.codex-secondary` |
| **Claude** | Claude Code OAuth 세션으로 `https://api.anthropic.com/api/oauth/usage`에서 조회한 라이브 사용량 | `user:profile` 범위와 유효한 만료 시각이 있는 Claude Code 로그인 |
| **Grok** | Grok CLI 세션으로 조회한 SuperGrok 크레딧 (필요 시 공식 OAuth 갱신, 프록시 우선, 사용량 누락 시 동일 세션 bearer의 제한된 billing fallback) | Grok CLI 로그인 및 `~/.grok/auth.json` |
| **Cursor** | Cursor 로컬 세션으로 조회한 계정 사용량 요약 | Cursor 앱 로그인 |
| **Doubao** | 공식 `arkcli usage plan --format json`의 플랜 한도 | `arkcli` 설치 및 유효한 SSO 로그인 |

Claude는 웹·데스크톱 앱과 별개인 **Claude Code 로그인**을 사용합니다. 토큰 만료가 60초 이내이거나 사용량 API가 HTTP 401을 반환하면 원본 저장소를 다시 읽고, 필요할 때 Claude Code의 제한된 `/usage` 실행으로 자동 갱신을 시도합니다. 새 토큰으로 사용량 요청을 한 번만 재시도하며, HTTP 403은 갱신하지 않습니다. 갱신 실패 뒤에는 5분 동안 백그라운드 재실행을 제한하지만, 새 로그인 정보는 다시 읽어 즉시 채택할 수 있습니다. 자동 복구가 불가능하면 터미널에서 `claude auth login`을 실행한 뒤 새로고침하세요.

Token Jar는 정확한 Claude Code 파일·키체인 계정의 AI OAuth만 읽고 MCP 토큰은 사용하지 않습니다. 거부된 토큰은 파일·키체인별로 기억해 번갈아 재사용하지 않습니다. 토큰 갱신·저장·잠금은 Claude Code가 담당하며 Token Jar가 토큰을 직접 수정하거나 다른 저장소에 복사하지 않습니다. 소유자 실행은 화면 잠금 해제 상태에서만 가능하고 시간·출력·입력이 제한됩니다. 백그라운드의 Token Jar 키체인 읽기는 승인창을 띄우지 않지만, 독립된 Claude Code 하위 프로세스의 macOS 승인창까지 억제한다고 보장하지는 않습니다. 브라우저 로그인이나 승인 절차는 자동화하지 않습니다.

자동 복구 회귀 테스트와 한·영 안내 UI, universal Release 빌드를 검증했습니다. 다만 검증 호스트의 Claude Code가 로그인되지 않은 상태여서 **실제 자연 만료·HTTP 401 이후 인증된 토큰 회전은 아직 검증하지 못했습니다.** 상세 보안 경계와 검증 기록은 [Distribution.md](TokenTankApp/Distribution/Distribution.md)와 [SecurityReview.md](TokenTankApp/Distribution/SecurityReview.md)를 참고하세요.

> **연동 범위에 주의하세요.** 모든 서비스가 안정적인 공개 사용량 API를 제공하지는 않습니다. Claude OAuth와 Grok·Cursor의 연동은 제공자 변경에 영향을 받을 수 있습니다. 세션·응답 형식이 달라지거나 승인된 경계를 벗어나면 데이터를 만들거나 다른 출처로 대체하지 않고 오류를 표시합니다. API 과금 전체를 합산하는 비용 관리 도구는 아닙니다.

정확한 경로, 조회 방식, 알려진 제한과 검증 상태는 [ProviderSources.json](TokenTankApp/Distribution/ProviderSources.json)에 기록되어 있습니다.

## 내 계정은 원래 있던 곳에

- 공식 도구가 소유한 인증 저장소는 원칙적으로 읽기 전용입니다. Claude 저장소는 정확히 읽기만 하며 Token Jar가 토큰을 직접 POST·수정·복사·저장·캐시하지 않습니다. 필요하면 제한된 Claude Code 소유자 `/usage`가 공식 잠금 아래 자신의 세션을 회전합니다.
- 유일한 직접 저장소 변경 예외인 Grok은 액세스 토큰 만료가 60초 이내이거나 첫 크레딧 프록시 요청이 401/403이면 `~/.grok/auth.json`의 기존 OIDC `refresh_token`을 공식 `https://auth.x.ai/oauth2/token`에 보내 갱신하고, 같은 파일에 새 액세스 토큰·만료 시각과 선택적으로 회전된 refresh token을 원자적으로 보존한 뒤 크레딧 요청을 한 번만 다시 시도합니다. 고정 issuer·선택된 client/scope 일치 검사를 거치며 브라우저 쿠키·CLI subprocess·수동 토큰 UI·Management API·Keychain 토큰 캐시를 사용하지 않습니다.
- 사용량 스냅샷은 메모리에만 유지합니다. 표시 설정은 로컬에 저장합니다.
- Codex와 Doubao는 허용된 공식 CLI를 실행합니다. 공식 CLI 자체의 세션 관리는 해당 도구가 담당합니다.
- 네트워크 조회가 필요한 서비스는 해당 제공자에 직접 요청합니다. 완전한 오프라인 앱은 아닙니다.
- 업데이트는 GitHub의 서명된 피드와 릴리즈 파일을 사용합니다. 계정·사용량·인증 정보를 보내지 않지만 GitHub/CDN에는 IP 주소 등 연결 정보가 전달됩니다. 업데이트 확인 설정과 다운로드 캐시는 Sparkle가 앱 전용으로 관리합니다.

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
In Settings, “Launch at Login” is off by default; enable it explicitly and approve it in macOS System Settings when prompted.

Provider names and logos belong to their respective owners. Token Jar is an independent project and is not endorsed by those providers. [CodexBar](https://github.com/steipete/CodexBar) is referenced for provider integration behavior; it is not a runtime dependency. The README banner was generated with GPT Image 2 through ima2 using the app icon as a visual reference.

## 라이선스

[MIT License](LICENSE). 자유롭게 사용·수정·재배포할 수 있습니다. 포함된 브랜드 아이콘의 라이선스와 상표 고지는 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)를 참고하세요.
