# TabDisplay

Android 태블릿을 macOS 확장 모니터로 쓰는 도구. USB로 연결하면 Mac에 가상 디스플레이가 생기고,
그 화면이 태블릿에 전체화면으로 스트리밍된다. 소리는 Mac에서 나온다.

터치: 탭=클릭(두 번 탭=더블클릭), 한 손가락 드래그=마우스 드래그, 두 손가락 드래그=스크롤, 길게 누르기=우클릭.

```
Mac: CGVirtualDisplay ─▶ ScreenCaptureKit ─▶ VideoToolbox H.264 ─▶ WebSocket :8801
                                                                        │ adb reverse (USB, adb 내장)
Android: OkHttp WebSocket ─▶ MediaCodec (HW) ─▶ SurfaceView (immersive) ◀┘
```

## 설치

[Releases](../../releases/latest)에서 받는다.

### Mac (Apple Silicon, macOS 14+)
1. `TabDisplay-x.y.z-macos.zip`을 풀고 `TabDisplay.app`을 **응용 프로그램** 폴더로 옮긴다.
2. 연다. Apple 공증을 받지 않은 앱이라 처음엔 "열 수 없음"이 뜬다 →
   **시스템 설정 > 개인정보 보호 및 보안** 맨 아래 **"그래도 열기"** → 다시 연다.
3. 뜨는 **TabDisplay 설정** 창의 항목을 위에서부터 누르면 된다.
   화면 녹화 · 손쉬운 사용 권한, 로그인 시 자동 실행, 태블릿 연결 상태, 태블릿 앱 설치까지 안내한다.
   (메뉴 막대 아이콘 ▭ 에서 언제든 다시 열 수 있다.)

adb는 앱에 들어 있다(설치 불필요). 이미 설치된 adb가 있으면 그걸 쓴다.

### Android
1. 개발자 옵션 > **USB 디버깅**을 켠다. (설정 > 태블릿 정보 > 빌드 번호 7번 탭 → 개발자 옵션)
2. USB로 Mac에 연결하고 "USB 디버깅 허용"에서 **항상 허용**.
3. 태블릿 앱은 Mac 설정 창의 **[설치]** 버튼으로 USB 설치하거나, `TabDisplay-x.y.z.apk`를 받아 직접 설치.

이후로는 **꽂기만 하면** 기기 해상도에 맞는 확장 디스플레이가 켜지고 태블릿 앱이 자동 실행된다. 뽑으면 꺼진다.
화면 배치(시스템 설정 > 디스플레이 > 정렬)는 기기별로 기억된다.

## 개발

| 경로 | 내용 |
|------|------|
| `mac/` | Swift 앱. `mac/build.sh` → `mac/build/TabDisplay.app` (`APK_PATH=…`로 APK 동봉) |
| `android/` | 뷰어 APK (`kr.rimgosu.tabdisplay`) |

로그: `~/Library/Logs/tabdisplay.log`

`v*` 태그를 push하면 GitHub Actions가 서명된 APK와 macOS 앱(zip, adb·APK 동봉)을 빌드해 Release에 올린다.
APK 서명 키는 repo secret `KEYSTORE_B64`(PKCS#12, alias `tabdisplay`) / `KEYSTORE_PASSWORD`.

> `mac/`은 비공개 API `CGVirtualDisplay`(DeskPad·BetterDisplay와 동일)를 쓴다. 동봉된 adb는 Android SDK Platform-Tools (Google).
