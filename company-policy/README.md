# Optional `company.com` Sample Policy

This sample demonstrates department-based access to data tagged with business
sensitivity and classification attributes. It extends the default federal
sample; it does not replace it.

## Recommended setup

From `dsp-standalone/`, provision the namespace, users, tagging overlay, and
validation tests through the main setup script:

```bash
# New stack
./setup_and_validate.sh \
  --bundle /path/to/virtru-dsp-bundle-2.0.6.6.tar.gz \
  --add-namespace company

# Already-running stack
./setup_and_validate.sh \
  --validate-only \
  --bundle .generated/virtru-dsp-bundle-2.0.6.6 \
  --add-namespace company
```

This is the supported customer workflow. It provisions
[sample.company_keycloak.yaml](../sample.company_keycloak.yaml),
[sample.company_policy.yaml](../sample.company_policy.yaml), and the additive
[company tagging overlay](../config/company.tagging-pdp-workflows.yaml).

## Policy model

| Attribute | Rule | Values |
|---|---|---|
| `department` | `ANY_OF` | engineering, hr, accounting, sales |
| `sensitivity` | `HIERARCHY` | confidential, public |
| `classification` | `ALL_OF` | pii, pci, phi, mnpi |

In the sensitivity hierarchy, `confidential` is higher than `public`.
Entitlement to confidential data therefore also grants access to public data.

Classification uses `ALL_OF`: a user must be entitled to every classification
value applied to the data.

## Sample users and entitlements

All four users have password `testuser123`.

| Username | Keycloak `dept` claim | Department | Sensitivity | Classification |
|---|---|---|---|---|
| `engineering-company-user` | Engineering | engineering | confidential and public | mnpi |
| `hr-company-user` | HR | hr | confidential and public | mnpi, pii, phi |
| `accounting-company-user` | Accounting | accounting | confidential and public | mnpi, pii, pci |
| `sales-company-user` | Sales | sales | confidential and public | mnpi, pii |

DSP normalizes policy attribute values to lowercase. The Keycloak `dept`
claims retain their displayed casing because subject conditions compare them
directly with token claims.

## Validate

The main setup command runs an SDK allow/deny test for this namespace. You can
also run the tagging checks directly:

```bash
./test_tagging.sh --namespace federal --namespace company
```

## Files

| File | Purpose |
|---|---|
| [../sample.company_keycloak.yaml](../sample.company_keycloak.yaml) | Users and their `dept` claims |
| [../sample.company_policy.yaml](../sample.company_policy.yaml) | Policy provisioner input used by setup |
| [../config/company.tagging-pdp-workflows.yaml](../config/company.tagging-pdp-workflows.yaml) | Tag extraction and resource mappings merged with the federal workflow |
| [company.com-policy.yaml](company.com-policy.yaml) | Reviewable tructl import/export representation |
| [create_company_policy.sh](create_company_policy.sh) | Advanced, create-only construction and export helper |
| [company.com-export.yaml](company.com-export.yaml) | Example output from the construction helper |

## Advanced construction helper

`create_company_policy.sh` builds the policy object by object with `tructl`
and exports the result. It is useful when developing the policy itself, but it
is not the normal setup path.

The helper is create-only and is not idempotent once its attributes and
mappings exist. Use a clean local database or a different `NAMESPACE` when
experimenting:

```bash
# Uses tructl from the unpacked bundle when available
./company-policy/create_company_policy.sh

# Or select it explicitly
TRUCTL=.generated/virtru-dsp-bundle-2.0.6.6/tructl \
  ./company-policy/create_company_policy.sh
```

The helper targets `https://local-dsp.virtru.com:8080` and the local
`opentdf` service client by default. Override `HOST`, `CLIENT_CREDS`,
`NAMESPACE`, or `EXPORT_FILE` only for an isolated development stack.

> The sample uses well-known local credentials and is not suitable for
> production or a network-exposed environment.
