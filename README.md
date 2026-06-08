# SmartThings Edge Drivers — Devy

Hobeian / Tuya Zigbee 24GHz mmWave 재실·모션 센서용 SmartThings Edge 드라이버 컬렉션입니다.

---

## 드라이버 목록

| 폴더 | 드라이버 이름 | 지원 기기 |
|------|--------------|-----------|
| `zg-204zk/` | Hobeian mmWave Presence Sensor (ZG-204ZK) | HOBEIAN ZG-204ZK |
| `zg-204zp/` | Hobeian mmWave Presence Sensor (ZG-204ZP) | Tuya TS0601 (`_TZE200_ka8l86iu`) |

---

## zg-204zk — HOBEIAN ZG-204ZK

### 기기 정보

| 항목 | 값 |
|------|----|
| 제조사 (manufacturer) | `HOBEIAN` |
| 모델 (model) | `ZG-204ZK` |
| 통신 | Zigbee (Tuya Cluster `0xEF00`) |

### 지원 기능 (Capabilities)

- `presenceSensor` — 재실 감지 (present / not present)
- `motionSensor` — 동작 감지 (active / inactive)
- `battery` — 배터리 잔량 (%)
- `refresh` — 수동 새로고침

### Tuya DP 맵

| DP | 타입 | 설명 |
|----|------|------|
| 1 | Bool | 재실/모션 상태 (1=감지, 0=없음) |
| 2 | Value | 정적 감지 감도 (0~10) |
| 4 | Value | 감지 거리 (cm 단위, 예: 300 = 3.0m) |
| 102 | Value | 감지 유지 시간 (초) |
| 107 | Bool | LED 표시기 (true=켜짐) |
| 121 | Value | 배터리 잔량 (%) |
| 122 | Bool | 간섭 방지 (true=활성) |
| 123 | Value | 동작 감도 (0~10) |

### 앱 설정 (Preferences)

| 설정 | 기본값 | 범위 |
|------|--------|------|
| 감지 유지 시간 (초) | 30 | 10 ~ 28800 |
| 감지 거리 (m) | 3.0 | 0.0 ~ 5.0 |
| 정적 감지 감도 | 5 | 0 ~ 10 |
| 동작 감지 감도 | 5 | 0 ~ 10 |
| LED 표시기 | true | boolean |
| 간섭 방지 | false | boolean |

---

## zg-204zp — Tuya TS0601 (`_TZE200_ka8l86iu`)

### 기기 정보

| 항목 | 값 |
|------|----|
| 제조사 (manufacturer) | `_TZE200_ka8l86iu` |
| 모델 (model) | `TS0601` |
| 통신 | Zigbee (IASZone + Tuya Cluster `0xEF00`) |

### 지원 기능 (Capabilities)

- `motionSensor` — 동작 감지 (active / inactive)
- `presenceSensor` — 재실 감지 (present / not present)
- `battery` — 배터리 잔량 (%)
- `refresh` — 수동 새로고침

### 특이사항

- 드라이버 초기화(init) 및 `doConfigure` 시 IASZone CIE Address 등록 수행
- IASZone Zone Enroll Request(cmd 0x01)에 자동으로 응답 (Enroll Response: Success)
- Tuya DP와 IASZone ZoneStatus 알림을 동시에 수신하여 이중으로 상태 갱신

### Tuya DP 맵

| DP | 타입 | 설명 |
|----|------|------|
| 1 | Bool | 모션/재실 상태 (1=감지, 0=없음) |
| 2 | Value | 정적 감지 감도 (0~10) |
| 4 | Value | 감지 거리 (cm 단위) |
| 102 | Value | 감지 유지 시간 (초) |
| 107 | Bool | LED 표시기 |
| 121 | Value | 배터리 잔량 (%) |
| 122 | Bool | 간섭 방지 |
| 123 | Value | 동작 감도 (0~10) |

### 앱 설정 (Preferences)

| 설정 | 기본값 | 범위 |
|------|--------|------|
| 감지 유지 시간 (초) | 30 | 10 ~ 28800 |
| 감지 거리 (m) | 5.0 | 0.0 ~ 5.0 |
| 정적 감지 감도 | 8 | 0 ~ 10 |
| 동작 감지 감도 | 8 | 0 ~ 10 |
| LED 표시기 | true | boolean |
| 간섭 방지 | false | boolean |

---

## 구조

```
.
├── zg-204zk/               # HOBEIAN ZG-204ZK 드라이버
│   ├── config.yml
│   ├── fingerprints.yml
│   ├── profiles/
│   │   └── presence-sensor.yml
│   └── src/
│       └── init.lua
└── zg-204zp/               # Tuya TS0601 TZE200_ka8l86iu 드라이버
    ├── config.yml
    ├── fingerprints.yml
    ├── profiles/
    │   └── motion-sensor.yml
    └── src/
        └── init.lua
```
