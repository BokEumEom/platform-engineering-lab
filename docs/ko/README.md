# 한국어 문서

[프로젝트 한국어 README](../../README.ko.md)

이 디렉터리는 `platform-engineering-lab`의 운영 문서를 한국어로 제공합니다. 새로운 운영 기준, runbook, architecture decision은 가능하면 영문 문서와 한국어 mirror를 함께 유지합니다.

## 현재 제공 문서

- [20 — Multi-signal Observability](20-multi-signal-observability.md)
- [21 — Kubernetes 운영환경 기준](21-kubernetes-operating-environment.md)
- [22 — Cilium / Hubble / eBPF 도입 로드맵](22-cilium-hubble-roadmap.md)
- [23 — Storage / PVC Smoke Runbook](23-storage-smoke-runbook.md)

## 문서 원칙

1. 저장소의 manifest나 CI 성공만으로 runtime healthy를 주장하지 않습니다.
2. 실제 로컬 실행 결과와 정적 구성 상태를 구분합니다.
3. destructive / privilege / public exposure / production 변경 경계는 별도 승인 대상으로 유지합니다.
4. 운영 문서에는 실행 명령, 기대 증거, 실패 시 확인 지점을 포함합니다.
5. 영문 canonical 문서와 한국어 mirror의 의미가 달라지지 않도록 핵심 상태를 같이 갱신합니다.

영문 문서는 `docs/README.md`를 canonical index로 사용하고, 운영 우선순위가 높은 문서부터 한국어 mirror를 확대합니다. 중복된 장문 가이드는 작은 주제별 문서로 분리하고 기존 경로는 호환용 entrypoint로 유지합니다.
