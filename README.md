# TabDisplay

Android 태블릿을 macOS 확장 모니터로 쓰는 도구. USB(adb)로 연결하면 Mac에 가상 디스플레이가 생기고,
그 화면이 태블릿에 전체화면으로 스트리밍된다. 유튜브 띄워두기 같은 용도. 소리는 Mac에서 나온다.

터치: 탭=클릭(두 번 탭=더블클릭), 한 손가락 드래그=마우스 드래그, 두 손가락 드래그=스크롤, 길게 누르기=우클릭.
터치 입력에는 Mac에서 TabDisplay의 **손쉬운 사용** 권한이 필요하다.

```
Mac: CGVirtualDisplay ─▶ ScreenCaptureKit ─▶ VideoToolbox H.264 ─▶ WebSocket :8801
                                                                        │ adb reverse (USB)
Android: OkHttp WebSocket ─▶ MediaCodec (HW) ─▶ SurfaceView (immersive) ◀┘
```

## 구성

| 경로 | 내용 |
|------|------|
| `mac/` | Swift 앱 (`TabDisplay.app`). adb로 태블릿 연결을 감시해 꽂으면 디스플레이 on / 뽑으면 off |
| `android/` | 뷰어 APK (`kr.rimgosu.tabdisplay`). [Releases](../../releases)에서 받는다 |

## 설치

### Mac
```sh
brew install --cask android-platform-tools
mac/build.sh                     # -> mac/build/TabDisplay.app
open mac/build/TabDisplay.app    # 첫 실행 시 화면 녹화 권한 허용
```
로그인 시 자동 실행하려면 `~/Library/LaunchAgents`에 `ProgramArguments`가
`mac/build/TabDisplay.app/Contents/MacOS/tabdisplay`인 LaunchAgent(`RunAtLoad`, `KeepAlive`)를 등록.
로그: `~/Library/Logs/tabdisplay.log`

옵션: `--stream 1920x1200 --fps 60 --mbps 16 --panel 2944x1840 --no-hidpi --no-adb --serial X`

### Android
태블릿에서 개발자 옵션 → USB 디버깅을 켜고:
```sh
adb install -r TabDisplay-x.y.z.apk
```
APK가 설치돼 있으면 Mac 앱이 연결 시 자동 실행한다(없으면 Chrome으로 `http://localhost:8800` 을 연다).

## 릴리즈
`v*` 태그를 push하면 GitHub Actions가 서명된 APK를 빌드해 Release에 올린다.
서명 키는 repo secret `KEYSTORE_B64`(PKCS#12, alias `tabdisplay`) / `KEYSTORE_PASSWORD`.

> `mac/`은 비공개 API `CGVirtualDisplay`(DeskPad·BetterDisplay와 동일)를 쓴다.
