#!/usr/bin/env python3
"""Live DSP entity-chain demonstration using the unchanged federal sample policy.

First initialize standalone with its existing setup command:
  ./setup_and_validate.sh --skip-prereqs --bundle /path/to/bundle
Then run this script (Python 3, no additional packages):
  ./entity_chain_poc.py
  ./entity_chain_poc.py --start  # start an already initialized standalone stack

Uses Alice from sample.keycloak.yaml as User A and creates/reuses the Keycloak
client entity-chain-agent-b and its service-account user as Agent B. It sets
Agent B's user attributes to TS / GBR / BBB on each run and leaves that demo
identity in Keycloak. Policy and existing users are not edited. Local sample
credentials and unverified local TLS are intentional for this prototype.

Each resource gets ONE combined GetDecision call. Separate GetDecisionBulk
calls are diagnostics showing the individual actors' decisions. All decisions,
entitlements, and resolved attributes come from the running DSP, never a local
policy simulation. Requests and results are saved under .generated/.
"""

import argparse
import datetime
import json
from pathlib import Path
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parent
DSP = "https://local-dsp.virtru.com:8080"
KC = "https://local-dsp.virtru.com:18443/auth"
AUTHZ = DSP + "/authorization.v2.AuthorizationService/"
ERS = DSP + "/entityresolution.v2.EntityResolutionService/"
AGENT_CLIENT = "entity-chain-agent-b"
TLS = ssl._create_unverified_context()


def http(url, body=None, token=None, method=None, form=False):
    headers = {"Accept": "application/json"}
    data = None
    if body is not None:
        headers["Content-Type"] = (
            "application/x-www-form-urlencoded" if form else "application/json"
        )
        data = (urllib.parse.urlencode(body) if form else json.dumps(body)).encode()
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, context=TLS, timeout=60) as response:
            content = response.read()
            return json.loads(content) if content else None
    except urllib.error.HTTPError as error:
        raise RuntimeError(
            f"{request.get_method()} {url}: HTTP {error.code}\n"
            + error.read().decode()
        ) from error


def token(realm, **credentials):
    return http(
        KC + f"/realms/{realm}/protocol/openid-connect/token",
        credentials,
        form=True,
    )["access_token"]


def show(label, value):
    print(f"\n{label}", flush=True)
    print(json.dumps(value, indent=2), flush=True)


def identifier(entities, name):
    return {"entityChain": {"ephemeralId": name, "entities": entities}}


def resource(name, classification, compartments, countries):
    values = [("classification", classification)]
    values += [("needtoknow", value) for value in compartments]
    values += [("relto", value) for value in countries]
    return {
        "ephemeralId": name,
        "attributeValues": {
            "fqns": [f"https://demo.com/attr/{attribute}/value/{value}" for attribute, value in values]
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--start", action="store_true", help="Start the initialized Compose stack first")
    args = parser.parse_args()
    if args.start:
        compose = ["docker", "compose", "-f", "docker-compose.yaml"]
        if subprocess.check_output(["uname", "-s"], text=True).strip() == "Darwin":
            compose += ["-f", "docker-compose.mac.yml"]
        subprocess.run(compose + ["up", "-d", "--wait"], cwd=ROOT, check=True)

    print("DSP entity-chain POC: unchanged demo.com federal policy", flush=True)
    print("User A = Alice (S / USA / AAA, BBB, INT, OPS)")
    print("Agent B = Keycloak service-account user (TS / GBR / BBB)")
    print("Both actors are CATEGORY_SUBJECT. HTTP caller = opentdf service client.")

    admin = token("master", grant_type="password", client_id="admin-cli", username="admin", password="changeme")
    caller = token("opentdf", grant_type="client_credentials", client_id="opentdf", client_secret="secret")
    admin_url = KC + "/admin/realms/opentdf"
    clients = http(admin_url + "/clients?" + urllib.parse.urlencode({"clientId": AGENT_CLIENT}), token=admin)
    if not clients:
        http(admin_url + "/clients", {
            "clientId": AGENT_CLIENT,
            "name": "Entity chain POC Agent B",
            "enabled": True,
            "protocol": "openid-connect",
            "publicClient": False,
            "serviceAccountsEnabled": True,
            "clientAuthenticatorType": "client-secret",
            "secret": "secret",
        }, token=admin)
        clients = http(admin_url + "/clients?" + urllib.parse.urlencode({"clientId": AGENT_CLIENT}), token=admin)
    agent_account = http(admin_url + f"/clients/{clients[0]['id']}/service-account-user", token=admin)
    agent_account["attributes"] = {"clearance": ["TS"], "nationality": ["GBR"], "needToKnow": ["BBB"]}
    http(admin_url + f"/users/{agent_account['id']}", agent_account, token=admin, method="PUT")

    user = {"ephemeralId": "user-a", "emailAddress": "aaa@secret.usa", "category": "CATEGORY_SUBJECT"}
    agent = {"ephemeralId": "agent-b", "userName": agent_account["username"], "category": "CATEGORY_SUBJECT"}
    chain = [user, agent]
    evidence = {"dsp": DSP, "policy": "default federal / demo.com", "callerClientId": "opentdf", "scenarios": []}

    # These diagnostic calls expose the same resolution and mapping used inside GetDecision.
    resolved_request = {"entities": chain}
    show("ResolveEntities request", resolved_request)
    resolved = http(ERS + "ResolveEntities", resolved_request, caller)
    show("DSP resolved Keycloak records (independent attributes for each actor)", resolved)
    evidence["resolution"] = {"request": resolved_request, "response": resolved}
    entitlement_request = {"entityIdentifier": identifier(chain, "user-and-agent"), "withComprehensiveHierarchy": True}
    entitlements = http(AUTHZ + "GetEntitlements", entitlement_request, caller)
    show("GetEntitlements (hierarchy expanded; attributed to each ephemeralId)", entitlements)
    evidence["entitlements"] = {"request": entitlement_request, "response": entitlements}

    scenarios = [
        ("shared-access", "secret", ["bbb"], ["fvey"], "Both actors have Secret, BBB, and FVEY."),
        ("user-clearance-denied", "topsecret", ["bbb"], ["fvey"], "Agent has TS; Alice has S. Agent cannot elevate Alice."),
        ("agent-compartment-denied", "secret", ["aaa"], ["fvey"], "Alice has AAA; Agent has only BBB. Alice cannot lend AAA to Agent."),
        ("all-compartments", "secret", ["aaa", "bbb"], ["fvey"], "ALL_OF requires each actor to have both AAA and BBB."),
        ("split-entitlements", "topsecret", ["aaa"], ["fvey"], "Agent has TS, Alice has AAA. Pooling would permit; separate evaluation should deny."),
        ("usa-only", "secret", ["bbb"], ["usa"], "Alice is USA; Agent is GBR. Agent should deny."),
        ("gbr-only", "secret", ["bbb"], ["gbr"], "Agent is GBR; Alice is USA. Alice should deny."),
        ("either-country", "secret", ["bbb"], ["usa", "gbr"], "ANY_OF lets each actor match a different country on the SAME resource."),
        ("lower-clearance", "confidential", ["bbb"], ["fvey"], "HIERARCHY lets S and TS actors read Confidential."),
    ]
    rows = []
    for name, classification, compartments, countries, explanation in scenarios:
        print(f"\n{'=' * 72}\n{name}: {explanation}", flush=True)
        doc = resource(name, classification, compartments, countries)
        request = {"entityIdentifier": identifier(chain, "user-and-agent"), "action": {"name": "read"}, "resource": doc}
        show("ONE GetDecision request for the two-actor chain", request)
        started = time.monotonic()
        response = http(AUTHZ + "GetDecision", request, caller)
        elapsed = round((time.monotonic() - started) * 1000, 1)
        show(f"Combined DSP response ({elapsed} ms)", response)

        diagnostics_request = {"decisionRequests": [
            {"entityIdentifier": identifier([actor], actor["ephemeralId"]), "action": {"name": "read"}, "resources": [doc]}
            for actor in chain
        ]}
        diagnostics = http(AUTHZ + "GetDecisionBulk", diagnostics_request, caller)
        show("Separate bulk diagnostic: User A first, Agent B second", diagnostics)
        individual = [item["resourceDecisions"][0]["decision"] for item in diagnostics["decisionResponses"]]
        rows.append([name, *individual, response["decision"]["decision"]])
        evidence["scenarios"].append({
            "name": name, "explanation": explanation, "request": request, "response": response,
            "elapsedMs": elapsed, "diagnosticRequest": diagnostics_request, "diagnosticResponse": diagnostics,
        })

    print(f"\n{'=' * 72}\nAgent identity representation", flush=True)
    client_entity = {"ephemeralId": "agent-client", "clientId": AGENT_CLIENT, "category": "CATEGORY_SUBJECT"}
    client_resolution = http(ERS + "ResolveEntities", {"entities": [client_entity]}, caller)
    # Client representations may contain a client secret; display only identity and attributes.
    client_view = {"entityRepresentations": [
        {"originalId": item["originalId"], "additionalProps": [
            {key: props[key] for key in ("id", "clientId", "attributes") if key in props}
            for props in item.get("additionalProps", [])
        ]} for item in client_resolution["entityRepresentations"]
    ]}
    show("clientId resolves the client record, not its service-account user", client_view)
    client_request = {
        "entityIdentifier": identifier([user, client_entity], "user-and-client"),
        "action": {"name": "read"},
        "resource": resource("client-record-control", "secret", ["bbb"], ["fvey"]),
    }
    show("Same shared-access resource with agent represented by clientId", client_request)
    client_response = http(AUTHZ + "GetDecision", client_request, caller)
    show("Client-record chain response", client_response)
    evidence["clientIdentityControl"] = {"resolution": client_view, "request": client_request, "response": client_response}

    # Inspect automatic identity extraction too; never print or persist the access token.
    agent_token = token("opentdf", grant_type="client_credentials", client_id=AGENT_CLIENT,
                        client_secret=http(admin_url + f"/clients/{clients[0]['id']}/client-secret", token=admin)["value"])
    token_chain = http(ERS + "CreateEntityChainsFromTokens", {"tokens": [{"ephemeralId": "agent-token", "jwt": agent_token}]}, caller)
    show("DSP chain extracted from Agent B's genuine client-credentials token", token_chain)
    evidence["agentTokenChain"] = token_chain
    print("A service-account token selects clientId as its subject in this runtime.")
    print("It does not automatically include Alice or read the service-account user's attributes.")
    print("The two-actor proof explicitly identifies Alice and the agent service-account USER.")
    print("This demonstrates policy decisions for supplied identities; it does not establish delegation.")

    print("\nActual DSP decisions (individual columns are separate bulk diagnostics):")
    print(f"{'Resource':28} {'User A':10} {'Agent B':10} {'Chain':10}")
    for row in rows:
        name, *decisions = row
        print(f"{name:28} " + " ".join(f"{decision.removeprefix('DECISION_'):10}" for decision in decisions))

    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output = ROOT / ".generated" / "entity-chain-poc" / timestamp / "evidence.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"\nRequests and live responses: {output}")
    print(f"Demo agent retained in Keycloak: {AGENT_CLIENT} / {agent_account['username']}")


if __name__ == "__main__":
    main()
