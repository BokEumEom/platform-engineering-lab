# Multi-signal Observability

[English](../20-multi-signal-observability.md) | **한국어**

Reference environment는 metrics, logs, traces, alerts, Kubernetes runtime state를 서로 다른 evidence source로 취급합니다. 구성 요소가 설치되어 있다는 사실만으로 정상 동작을 주장하지 않고, full smoke에서 실제 application traffic이 각 backend까지 전달되는지 검증합니다.

## Runtime path

```text
Application metrics → Prometheus
Application stdout JSON → Alloy → Loki
Application OTLP traces → OpenTelemetry Collector → Tempo
PrometheusRule → Prometheus → Alertmanager

Harness / operator
  → MetalLB / Envoy Gateway
     → Prometheus API
     → Loki API
     → Tempo API
     → Alertmanager API
```

## Canonical smoke

```bash
bash ops/smoke/full-reference-environment.sh
```

검증 항목:

1. Loki / Tempo / Alertmanager HTTPRoute가 Accepted + ResolvedRefs인지 확인합니다.
2. `kubectl port-forward`가 아니라 MetalLB → Envoy Gateway 경로로 API가 접근되는지 확인합니다.
3. `web.lab.local`을 통해 실제 요청을 발생시킵니다.
4. Loki에 최신 `demo-app` 로그가 존재하는지 확인합니다.
5. Tempo에 최신 trace가 존재하는지 확인합니다.
6. Prometheus firing alert signal과 Alertmanager status API를 확인합니다.
7. Harness Loki/Tempo read-only adapter가 unavailable 없이 evidence를 생성하는지 확인합니다.
8. Loki log의 `trace_id`를 Tempo `/api/traces/{trace_id}`로 직접 조회해 최소 한 건 이상 실제 상관관계를 확인합니다.

## Agent 판단 경계

현재 Loki/Tempo evidence는 다음 원칙을 유지합니다.

```text
decision_effect = enrichment_only
```

즉 Kubernetes + Prometheus가 만든 기존 `ops-review` 상태를 로그/트레이스가 자동으로 뒤집지 않습니다.

```text
Kubernetes + Prometheus
        ↓
base Ops decision
        ↓
Loki structured log
        ↓ trace_id
Tempo exact trace lookup
        ↓
enrichment correlation
```

이 구조는 이미 로컬 full smoke에서 live verified 됐습니다.

검증된 결과 예시:

```text
Prometheus service coverage   6/6
Loki application logs         100 entries
Tempo recent traces           20
Harness Loki entries          50
Harness Tempo traces          23
exact Tempo traces observed   4
correlation count             4
source unavailable            []
status                        correlated
decision effect               enrichment_only
```

## 현재 local-lab 내구성 경계

- Prometheus: 24h retention, persistent volume 없음
- Loki: 24h retention, single replica, filesystem, persistent volume 없음
- Tempo: 6h retention, single replica, local storage, persistent volume 없음
- Alertmanager: 24h retention, receiver는 아직 `null`

따라서 현재 구성은 반복 가능한 incident evaluation에는 적합하지만 production HA telemetry 구조는 아닙니다.

## 다음 단계

- PVC / storage metrics와 alert를 Agent evidence에 포함
- NetworkPolicy failure scenario
- Cilium / Hubble network-flow evidence
- telemetry-loss scenario
- external alert delivery
- observability API authentication / authorization
- synthetic monitoring
- multi-signal evidence가 root-cause localization을 실제로 개선하는지 evaluation으로 검증
