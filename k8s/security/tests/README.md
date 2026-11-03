# Kyverno policy tests — offline proof, no cluster needed

Each directory holds a `kyverno-test.yaml` (Kyverno CLI test manifest) plus
minimal Deployment resources. Run them with the Kyverno CLI
(https://github.com/kyverno/kyverno/releases — match the pinned chart's
Kyverno version, currently v1.19.2):

```bash
kyverno test k8s/security/tests/disallow-latest
kyverno test k8s/security/tests/require-limits
kyverno test k8s/security/tests/require-pod-security
kyverno test k8s/security/tests/require-signatures   # needs network: GHCR + Rekor
```

What each suite proves:

| Suite | Proves |
|---|---|
| `disallow-latest` | `:latest` image → REJECTED; `:sha` image → ALLOWED |
| `require-limits` | container without resources → REJECTED; with requests+limits → ALLOWED |
| `require-pod-security` | privileged container → REJECTED; missing runAsNonRoot → REJECTED; compliant pod → ALLOWED |
| `require-signatures` | real GHCR image built before signing existed → REJECTED (no signature found) |

The `require-signatures` negative case uses a genuine image
(`ghcr.io/samir-khadka/shipit-api:065f2a4b…`, built by Phase 0 CI) that was
never signed — verification really runs against the registry and Rekor.

The positive case (a signed image is ALLOWED) is proven by CI itself: every
main-branch build signs its images with keyless cosign, and the Kyverno
admission check verifies that exact signature. To re-verify by hand against
the current signed images:

```bash
cosign verify \
  --certificate-identity "https://github.com/Samir-Khadka/shipit-platform/.github/workflows/ci.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/samir-khadka/shipit-api:<sha>
```
