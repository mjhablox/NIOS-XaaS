"""
DDIaaS DHCP Service Upgrade Script
Creates a Universal Service with DHCP capability, provisions the full infrastructure,
creates DHCP resources, sets up IPsec tunnel, verifies DHCP lease, then pauses for
manual FeatureFlagOverride upgrade on the cluster, and verifies DHCP lease post-upgrade.

Usage: python3 test_ddiaas_dhcp_service.py [--no-cleanup]
  Requires env vars: CSP_URL, CSP_API_TOKEN
  Options:
    --no-cleanup    Skip resource cleanup after run
  Example:
    export CSP_URL=env-2a.test.infoblox.com
    export CSP_API_TOKEN=your_api_token
    python3 test_ddiaas_dhcp_service.py
    python3 test_ddiaas_dhcp_service.py --no-cleanup
    CSP_API_TOKEN="7be62b45741a02d96eca65365b1605709dfea81c14168fbf7979722f3f390003" python3 /Users/n.joshi/deployment/atlas.qa/e2e_automation/test/test_ddiaas_dhcp_service.py
"""

import argparse
import os
import sys
import json
import time
import random
import logging
import subprocess
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# ── Configuration from env vars ──────────────────────────────────────────────
CSP_URL = os.environ.get("CSP_URL", "env-2a.test.infoblox.com")
CSP_API_TOKEN = os.environ.get("CSP_API_TOKEN", "")
WAN_IP = os.environ.get("WAN_IP", "18.208.227.129")
SERVICE_REGION = os.environ.get("SERVICE_REGION", "AWS US (N. Virginia)")

# SSH / Router config for IPsec tunnel
ROUTER_HOST = os.environ.get("ROUTER_HOST", "172.28.7.174")
ROUTER_USER = os.environ.get("ROUTER_USER", "ubuntu")
ROUTER_PEM = os.environ.get("ROUTER_PEM", "/Users/n.joshi/keys/ib-shared.pem")
ROUTER_PEM = os.environ.get("ROUTER_PEM", "/Users/mjha2/ib-shared.pem")

# FeatureFlagOverride config for upgrade
FFO_NAME = os.environ.get("FFO_NAME", "adc-ddiaas-dhcp-account-override-kea-2.6")
FFO_NAMESPACE = os.environ.get("FFO_NAMESPACE", "atlas-app-def-system")
POD_NAMESPACE = os.environ.get("POD_NAMESPACE", "ddiaas-dhcp-endpoint")

if not CSP_API_TOKEN:
    logger.error("CSP_API_TOKEN environment variable must be set")
    sys.exit(1)

BASE_URL = "https://{}".format(CSP_URL)

# ── Global state ─────────────────────────────────────────────────────────────
univ_id = ''
cred_id = ''
location_id = ''
endpoint_id = ''
access_location_id = ''
ip_space_id = ''
dhcp_subnet_id = ''
dhcp_range_id = ''
service_ip = ''
cnames = []
left_ids = {}  # dict keyed by path: {'primary': id, 'secondary': id}
ipsec_containers = {}  # dict: {'pri': container_name, 'sec': container_name}

time_str = time.strftime("%m-%d-%y-%H-%M-%S")
us_name = "auto_test_dhcp_" + time_str
dhcp_ip_space_name = us_name + "-ip-space"
psk_value = "AutoTestDHCP123456789!"

# Names for sub-objects
cred_name = us_name + "-psk"
loc_name = us_name + "-loc"
ep_name = us_name + "-ep"
al_name = us_name + "-access"


# ── Auth / API ───────────────────────────────────────────────────────────────
def get_headers(token):
    """Return standard auth + JSON headers."""
    return {
        "Authorization": "Token {}".format(token),
        "Content-Type": "application/json",
    }


def api_call(token, verb, path, payload=None):
    """Generic CSP API call. Returns parsed JSON on success, None on failure."""
    url = "{}/{}".format(BASE_URL, path.lstrip("/"))
    headers = get_headers(token)

    resp = requests.request(verb, url, headers=headers, json=payload, verify=False)

    if resp.status_code >= 400:
        logger.error("API {} {} returned {}: {}".format(verb, path, resp.status_code, resp.text[:500]))
        return None

    try:
        return resp.json()
    except Exception:
        return {"status_code": resp.status_code}


# ── Service helpers ──────────────────────────────────────────────────────────
def check_service_status(token, universal_service_id, max_wait=1800, interval=15):
    """Poll until DHCP capability shows 'Available' or timeout."""
    elapsed = 0
    logger.info("Polling service status for up to {} seconds".format(max_wait))

    while elapsed < max_wait:
        payload = {
            "perspective": "configuration/location",
            "universal_service_id": universal_service_id,
        }
        response = api_call(token, "POST",
                            "api/universalinfra/v1/consolidated/getcapabilities",
                            payload=payload)

        if response:
            capabilities = response.get('universal_service', {}).get('capabilities', [])
            statuses = {cap.get('type'): cap.get('service_status', 'unknown') for cap in capabilities}
            logger.info("Service statuses: {}".format(statuses))

            all_available = all(
                cap.get('service_status') == 'Available'
                for cap in capabilities if cap.get('service_status')
            )
            if all_available and capabilities:
                logger.info("All services are available!")
                return True
        else:
            logger.warning("Empty response from getcapabilities")

        time.sleep(interval)
        elapsed += interval

    logger.error("Services did not become available within {} seconds".format(max_wait))
    return False


# ── Cleanup ──────────────────────────────────────────────────────────────────
def delete_by_name(token, object_type, name):
    """Find a universalinfra object by name via GET, then DELETE it."""
    # GET to find the object
    get_url = 'api/universalinfra/v1/{}?_filter=name=="{}"'.format(object_type, name)
    resp = api_call(token, "GET", get_url)
    if resp and 'results' in resp and resp['results']:
        obj_id = resp['results'][0]['id'].split("/")[-1]
        # DELETE with the found ID
        del_url = "api/universalinfra/v1/{}/{}".format(object_type, obj_id)
        del_resp = api_call(token, "DELETE", del_url)
        if del_resp is not None:
            logger.info("Deleted {} '{}' (ID: {})".format(object_type, name, obj_id))
            return True
        else:
            logger.warning("DELETE failed for {} '{}' (ID: {})".format(object_type, name, obj_id))
    else:
        logger.warning("{} '{}' not found for deletion".format(object_type, name))
    return False


def delete_with_retry(token, path, label, max_attempts=6, delay=15):
    """DELETE a resource via REST, retrying on 409 (operation in progress)."""
    for attempt in range(max_attempts):
        if attempt > 0:
            logger.info("Retrying DELETE {} (attempt {}/{}) after {}s...".format(label, attempt + 1, max_attempts, delay))
            time.sleep(delay)
        resp = api_call(token, "DELETE", path)
        if resp is not None:
            logger.info("Deleted {} via DELETE {}".format(label, path))
            return True
    logger.warning("Could not delete {} after {} attempts".format(label, max_attempts))
    return False


def cleanup(token):
    """Tear down all created resources in reverse order.

    Cleanup order:
      1. DHCP resources (range → subnet → ip_space) via DELETE /api/ddi/v1/...
      2. access_location via DELETE /api/universalinfra/v1/accesslocations/<id>
      3. endpoint (service connection) via DELETE /api/universalinfra/v1/endpoints/<id>
      4. universal_service via DELETE /api/universalinfra/v1/universalservices/<id>
         — this cascades and also removes the location and credential
    """
    logger.info("Starting cleanup")

    # 0. Remove IPsec Docker containers on the remote router
    for label, cname in ipsec_containers.items():
        try:
            ssh_cmd(ROUTER_HOST, ROUTER_USER, ROUTER_PEM,
                    "sudo docker rm -f {}".format(cname))
            logger.info("Removed IPsec container {} ({})".format(label, cname))
        except Exception as e:
            logger.warning("Failed to remove IPsec container {} ({}): {}".format(label, cname, e))

    # 1. Delete DHCP range, subnet, IP space
    for label, resource_id in [("range", dhcp_range_id),
                                ("subnet", dhcp_subnet_id),
                                ("ip_space", ip_space_id)]:
        if resource_id:
            try:
                api_call(token, "DELETE", "api/ddi/v1/{}".format(resource_id))
                logger.info("Deleted {} ({})".format(label, resource_id))
                time.sleep(1)
            except Exception as e:
                logger.warning("Failed to delete {} {}: {}".format(label, resource_id, e))

    # 2. Delete access_location via REST DELETE
    if access_location_id:
        delete_with_retry(token, "api/universalinfra/v1/accesslocations/{}".format(access_location_id),
                          "access_location ({})".format(access_location_id), max_attempts=4, delay=10)

    # 3. Delete endpoint (service connection) via REST DELETE
    if endpoint_id:
        delete_with_retry(token, "api/universalinfra/v1/endpoints/{}".format(endpoint_id),
                          "endpoint ({})".format(endpoint_id), max_attempts=6, delay=15)

    # 4. Delete universal service via REST DELETE — cascades location + credential
    if univ_id:
        delete_with_retry(token, "api/universalinfra/v1/universalservices/{}".format(univ_id),
                          "universal_service {} ({})".format(us_name, univ_id), max_attempts=4, delay=10)

    logger.info("Cleanup complete")


# ── Step 1: Create Universal Service with full infrastructure ────────────────
def create_universal_service_with_infra(token):
    """
    Create Universal Service + credential + location + service connection +
    access location in a single consolidated API call.
    """
    global univ_id, cred_id, location_id, endpoint_id, access_location_id, service_ip

    logger.info("Creating Universal Service with full infrastructure: {}".format(us_name))

    # Generate a private IP for the service endpoint
    service_ip = "10.10.10.1"
    neighbour_ip1 = "10.10.10.2"
    neighbour_ip2 = "10.10.10.3"

    us_payload = {
        "universal_service": {
            "operation": "CREATE",
            "name": us_name,
            "description": "DEPLOY",
            "capabilities": [
                {"type": "dhcp", "profile_id": ""}
            ]
        },
        "credentials": {
            "create": [{
                "id": "ref_cred_{}".format(cred_name),
                "name": cred_name,
                "type": "psk",
                "description": "AUTOMATION-KEY",
                "value": psk_value
            }]
        },
        "locations": {
            "create": [{
                "id": "ref_loc_{}".format(loc_name),
                "name": loc_name,
                "address": {"country": "US", "postal_code": "10001"},
                "latitude": 40.7,
                "longitude": -74.0
            }]
        },
        "endpoints": {
            "create": [{
                "id": "ref_endpoint_{}".format(ep_name),
                "name": ep_name,
                "size": "S",
                "service_location": SERVICE_REGION,
                "service_ip": service_ip,
                "neighbour_ips": [neighbour_ip1, neighbour_ip2],
                "preferred_provider": "AWS",
                "routing_type": "static"
            }]
        },
        "access_locations": {
            "create": [{
                "endpoint_id": "ref_endpoint_{}".format(ep_name),
                "credential_id": "ref_cred_{}".format(cred_name),
                "location_id": "ref_loc_{}".format(loc_name),
                "wan_ip_addresses": [WAN_IP],
                "routing_type": "static",
                "tunnel_configs": [{
                    "name": us_name + "-tunnel",
                    "identity_type": "KeyID",
                    "wan_ip": WAN_IP,
                    "physical_tunnels": [
                        {"path": "primary", "credential_id": "ref_cred_{}".format(cred_name)},
                        {"path": "secondary", "credential_id": "ref_cred_{}".format(cred_name)}
                    ]
                }]
            }]
        }
    }

    response = api_call(token, "POST",
                        "api/universalinfra/v1/consolidated/configure",
                        payload=us_payload)

    if not response or 'universal_service' not in response:
        logger.error("Failed to create universal service: {}".format(response))
        return False

    # Extract IDs for cleanup
    univ_id = response['universal_service']['id'].split("/")[-1]
    logger.info("Universal service created: {} (ID: {})".format(us_name, univ_id))

    if 'credentials' in response and 'created' in response['credentials'] and response['credentials']['created']:
        cred_id = response['credentials']['created'][0]['id'].split("/")[-1]
        logger.info("Credential created: {} (ID: {})".format(cred_name, cred_id))

    if 'locations' in response and 'created' in response['locations'] and response['locations']['created']:
        location_id = response['locations']['created'][0]['id'].split("/")[-1]
        logger.info("Location created: {} (ID: {})".format(loc_name, location_id))

    if 'endpoints' in response and 'created' in response['endpoints'] and response['endpoints']['created']:
        endpoint_id = response['endpoints']['created'][0]['id'].split("/")[-1]
        # Get the actual service IP assigned
        actual_ip = response['endpoints']['created'][0].get('service_ip', service_ip)
        service_ip = actual_ip
        logger.info("Service connection created: {} (ID: {}, IP: {})".format(ep_name, endpoint_id, service_ip))

    if 'access_locations' in response and 'created' in response['access_locations'] and response['access_locations']['created']:
        access_location_id = response['access_locations']['created'][0]['id'].split("/")[-1]
        logger.info("Access location created: {} (ID: {})".format(al_name, access_location_id))

    logger.info("Full infrastructure created. Waiting 30s for propagation...")
    time.sleep(30)
    return True


# ── Step 2: Wait for DHCP to become Available ────────────────────────────────
def wait_for_dhcp_available(token):
    """Poll until DHCP service status is Available."""
    logger.info("Waiting for DHCP service to become Available")
    return check_service_status(token, univ_id)


# ── Step 3: Create IP Space ──────────────────────────────────────────────────
def create_dhcp_ip_space(token):
    """Create an IP space."""
    global ip_space_id
    logger.info("Creating IP space: {}".format(dhcp_ip_space_name))

    payload = {"name": dhcp_ip_space_name}
    response = api_call(token, "POST", "api/ddi/v1/ipam/ip_space", payload=payload)

    if not response or 'result' not in response or 'id' not in response.get('result', {}):
        logger.error("Failed to create IP space: {}".format(response))
        return False

    ip_space_id = response['result']['id']
    logger.info("IP space created: {} (ID: {})".format(dhcp_ip_space_name, ip_space_id))
    return True


# ── Step 4: Create Subnet ────────────────────────────────────────────────────
def create_dhcp_subnet(token):
    """Create a /24 subnet in the IP space, assigned to the DHCP service."""
    global dhcp_subnet_id
    if not ip_space_id:
        logger.error("IP space must be created first")
        return False

    logger.info("Creating DHCP subnet 10.10.10.0/24")

    # Find the DHCP host (service) for this universal service
    # The host name matches the universal service name (e.g. "auto_test_dhcp_...")
    # DHCP host can take 15-25 minutes to appear after service becomes Available
    dhcp_host_id = ""
    max_attempts = 60  # 60 x 30s = 30 minutes
    for attempt in range(max_attempts):
        if attempt > 0:
            logger.info("Waiting 30s before retrying DHCP host lookup (attempt {}/{})...".format(attempt + 1, max_attempts))
            time.sleep(30)
        else:
            time.sleep(30)  # Initial wait for DHCP DB propagation

        for name_pattern in [us_name, "DHCP " + us_name]:
            dhcp_host_filter = 'api/ddi/v1/dhcp/host?_filter=name=="{}"'.format(name_pattern)
            host_resp = api_call(token, "GET", dhcp_host_filter)
            if host_resp and 'results' in host_resp and host_resp['results']:
                dhcp_host_id = host_resp['results'][0]['id']
                logger.info("Found DHCP host: {} (name: {})".format(dhcp_host_id, name_pattern))
                break
        if dhcp_host_id:
            break

    if not dhcp_host_id:
        logger.error("DHCP host not found after retries — cannot create subnet without host assignment")
        return False

    payload = {
        "address": "10.10.10.0",
        "cidr": 24,
        "space": ip_space_id,
        "name": us_name + "-subnet",
        "dhcp_host": dhcp_host_id,
    }

    response = api_call(token, "POST", "api/ddi/v1/ipam/subnet", payload=payload)

    if not response or 'result' not in response or 'id' not in response.get('result', {}):
        logger.error("Failed to create DHCP subnet: {}".format(response))
        return False

    dhcp_subnet_id = response['result']['id']
    logger.info("DHCP subnet created (ID: {})".format(dhcp_subnet_id))
    return True


# ── Step 5: Create Range ─────────────────────────────────────────────────────
def create_dhcp_range(token):
    """Create an address range 10.10.10.1-10.10.10.251."""
    global dhcp_range_id
    if not ip_space_id or not dhcp_subnet_id:
        logger.error("IP space and subnet must be created first")
        return False

    logger.info("Creating DHCP range 10.10.10.1 - 10.10.10.251")

    payload = {
        "start": "10.10.10.1",
        "end": "10.10.10.251",
        "space": ip_space_id,
    }
    response = api_call(token, "POST", "api/ddi/v1/ipam/range", payload=payload)

    if not response or 'result' not in response or 'id' not in response.get('result', {}):
        logger.error("Failed to create DHCP range: {}".format(response))
        return False

    dhcp_range_id = response['result']['id']
    logger.info("DHCP range created (ID: {})".format(dhcp_range_id))
    return True


# ── SSH helper ────────────────────────────────────────────────────────────────
def ssh_cmd(host, user, pem, cmd):
    """Run a command on a remote host via SSH. Returns stdout."""
    ssh = [
        "ssh", "-i", pem, "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
        "{}@{}".format(user, host), cmd
    ]
    logger.info("SSH [{}]: {}".format(host, cmd))
    result = subprocess.run(ssh, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        logger.warning("SSH stderr: {}".format(result.stderr.strip()))
    return result.stdout.strip()


# ── Step 6: Get endpoint cnames (NLB IPs) ───────────────────────────────────
def get_endpoint_cnames(token):
    """Fetch cnames (NLB IPs) from the service endpoint. Retries until available."""
    global cnames
    if not endpoint_id:
        logger.error("Endpoint ID not set")
        return False

    for attempt in range(60):
        if attempt > 0:
            logger.info("Waiting 30s for cnames (attempt {}/60)...".format(attempt + 1))
            time.sleep(30)

        resp = api_call(token, "GET", "api/universalinfra/v1/endpoints/{}".format(endpoint_id))
        if resp and 'result' in resp:
            ep_data = resp['result']
        elif resp and 'id' in resp:
            ep_data = resp
        else:
            continue

        ep_cnames = ep_data.get('cnames', [])
        if len(ep_cnames) >= 2:
            cnames = ep_cnames
            logger.info("Endpoint cnames (NLB IPs): {}".format(cnames))
            return True
        elif len(ep_cnames) == 1:
            logger.info("Only 1 cname so far, waiting for second...")

    logger.error("Failed to get cnames after retries")
    return False


# ── Step 7: Get tunnel identities ────────────────────────────────────────────
def get_tunnel_identities(token):
    """Fetch tunnel identities (left IDs) from the access location. Retries up to 30 minutes."""
    global left_ids
    if not access_location_id:
        logger.error("Access location ID not set")
        return False

    max_attempts = 60  # 60 x 30s = 30 minutes
    for attempt in range(max_attempts):
        if attempt > 0:
            logger.info("Waiting 30s before retrying tunnel identity lookup (attempt {}/{})...".format(attempt + 1, max_attempts))
            time.sleep(30)

        resp = api_call(token, "GET", "api/universalinfra/v1/accesslocations/{}".format(access_location_id))
        if not resp:
            continue

        al_data = resp.get('result', resp)
        tunnel_configs = al_data.get('tunnel_configs', [])
        if not tunnel_configs:
            logger.info("No tunnel configs yet, retrying...")
            continue

        found_ids = {}
        for pt in tunnel_configs[0].get('physical_tunnels', []):
            identity = pt.get('identity', '')
            path = pt.get('path', '')
            if identity and path:
                found_ids[path] = identity
                logger.info("Tunnel {} identity (left_id): {}".format(path, identity))

        if found_ids:
            left_ids = found_ids
            return True
        else:
            logger.info("Tunnel configs present but no identities yet, retrying...")

    logger.error("Tunnel identities not found after 30 minutes of retries")
    return False


# ── Step 8: Setup IPsec tunnels (primary + secondary) ────────────────────────
def _start_tunnel(label, container_name, nlb_ip, left_id):
    """Start a single IPsec tunnel container. Returns True if ESTABLISHED."""
    right_id = "infoblox.cloud"
    docker_image = "infobloxcto/atlas.tap:ipsec-dras-py"
    managed_ip = service_ip  # 10.10.10.1
    dhcp_helper = "10.10.10.2"  # neighbour_ip1

    logger.info("Setting up {} IPsec tunnel: NLB={}, left_id={}, container={}".format(
        label, nlb_ip, left_id, container_name))

    # Remove any existing container with same name
    ssh_cmd(ROUTER_HOST, ROUTER_USER, ROUTER_PEM,
            "sudo docker rm -f {} 2>/dev/null || true".format(container_name))

    # Start container — entrypoint handles ipsec.conf generation and tunnel setup
    docker_run = (
        "sudo docker run -d --name {name} --privileged "
        "-v /lib/modules:/lib/modules "
        "-e REMOTE_IP={nlb_ip} "
        "-e PSK={psk} "
        "-e LEFT_ID={left_id} "
        "-e RIGHT_ID={right_id} "
        "-e MANAGED_IP={managed_ip} "
        "-e DHCP_HELPER={dhcp_helper} "
        "-e CONNECTION_NAME={name} "
        "{image}"
    ).format(
        name=container_name, nlb_ip=nlb_ip, psk=psk_value,
        left_id=left_id, right_id=right_id,
        managed_ip=managed_ip, dhcp_helper=dhcp_helper,
        image=docker_image
    )
    result = ssh_cmd(ROUTER_HOST, ROUTER_USER, ROUTER_PEM, docker_run)
    if not result:
        logger.error("Failed to start {} container".format(label))
        return False
    logger.info("{} container started: {}".format(label, result[:12]))
    return True


def setup_ipsec_tunnel(token):
    """Create two StrongSwan Docker containers (primary + secondary) on the remote router."""
    global ipsec_containers

    if not cnames or not left_ids:
        logger.error("cnames or left_ids not available")
        return False

    if len(cnames) < 2:
        logger.error("Need at least 2 cnames (NLB IPs), got {}".format(len(cnames)))
        return False

    # primary identity + cnames[0], secondary identity + cnames[1]
    tunnels = [
        ("pri", us_name + "-pri", cnames[0], left_ids.get('primary', '')),
        ("sec", us_name + "-sec", cnames[1], left_ids.get('secondary', '')),
    ]

    for label, container_name, nlb_ip, left_id in tunnels:
        if not left_id:
            logger.error("No {} identity available".format(label))
            return False
        ok = _start_tunnel(label, container_name, nlb_ip, left_id)
        if not ok:
            return False
        ipsec_containers[label] = container_name

    # Wait for both containers to set up tunnels
    logger.info("Waiting 30s for IPsec tunnels to establish...")
    time.sleep(30)

    # Verify both tunnels
    all_established = True
    for label, container_name in ipsec_containers.items():
        status = ssh_cmd(ROUTER_HOST, ROUTER_USER, ROUTER_PEM,
                         'sudo docker ps --filter name={} --format "{{{{.Status}}}}"'.format(container_name))
        logger.info("{} container status: {}".format(label, status))

        ipsec_status = ssh_cmd(ROUTER_HOST, ROUTER_USER, ROUTER_PEM,
                               "sudo docker exec {} ipsec status".format(container_name))
        logger.info("{} IPsec status: {}".format(label, ipsec_status))

        if "ESTABLISHED" in ipsec_status:
            logger.info("{} IPsec tunnel established!".format(label))
        else:
            logger.error("{} IPsec tunnel NOT established".format(label))
            all_established = False

    if all_established:
        logger.info("Both IPsec tunnels (pri + sec) established successfully!")
    return all_established


# ── Step 9: Request DHCP lease via dras ──────────────────────────────────────
def _run_dras_on_container(label, container_name):
    """Run dras on a single container. Returns True after 3 consecutive successes."""
    target_ip = service_ip  # 10.10.10.1
    required_consecutive = 3
    consecutive_success = 0
    max_attempts = 20
    wait_between = 30  # seconds

    logger.info("[{}] Requesting DHCP leases from {} via dras (need {} consecutive successes)".format(
        label, target_ip, required_consecutive))

    for attempt in range(1, max_attempts + 1):
        logger.info("[{}] dras attempt {}/{} (consecutive passes: {}/{})".format(
            label, attempt, max_attempts, consecutive_success, required_consecutive))

        dras_out = ssh_cmd(ROUTER_HOST, ROUTER_USER, ROUTER_PEM,
                           "sudo docker exec {} ./dras -i {} -n 1 2>&1".format(container_name, target_ip))
        logger.info("[{}] dras output:\n{}".format(label, dras_out))

        # Parse Completed count from output
        completed = 0
        for line in dras_out.splitlines():
            if line.strip().startswith("Completed:"):
                try:
                    completed = int(line.split(":")[1].strip())
                except (ValueError, IndexError):
                    pass

        if completed >= 1:
            consecutive_success += 1
            logger.info("[{}] Lease acquired! ({}/{} consecutive)".format(
                label, consecutive_success, required_consecutive))
            if consecutive_success >= required_consecutive:
                logger.info("[{}] DHCP lease verification passed — {} consecutive leases".format(
                    label, required_consecutive))
                return True
        else:
            logger.warning("[{}] No lease obtained, resetting consecutive counter".format(label))
            consecutive_success = 0

        if attempt < max_attempts:
            logger.info("[{}] Waiting {}s before next attempt...".format(label, wait_between))
            time.sleep(wait_between)

    logger.error("[{}] Failed to get {} consecutive DHCP leases after {} attempts".format(
        label, required_consecutive, max_attempts))
    return False


def request_dhcp_lease(token):
    """Run dras on both primary and secondary tunnel containers."""
    if not ipsec_containers:
        logger.error("IPsec containers not set")
        return False

    all_passed = True
    for label, container_name in ipsec_containers.items():
        ok = _run_dras_on_container(label, container_name)
        if not ok:
            all_passed = False

    if all_passed:
        logger.info("DHCP lease verification passed on all tunnels (pri + sec)")
    return all_passed


# ── Helper: run kubectl command ──────────────────────────────────────────────
def kubectl_cmd(cmd):
    """Run a kubectl command locally. Returns (stdout, success)."""
    logger.info("kubectl: {}".format(cmd))
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            logger.error("kubectl failed (rc={}): {}".format(result.returncode, result.stderr.strip()))
            return result.stdout.strip(), False
        return result.stdout.strip(), True
    except FileNotFoundError:
        logger.error("kubectl not found — ensure you are logged into the cluster")
        return "", False
    except subprocess.TimeoutExpired:
        logger.error("kubectl command timed out")
        return "", False


# ── Step 10: Update FeatureFlagOverride ──────────────────────────────────────
def update_featureflag_override(token):
    """Automatically patch the FeatureFlagOverride to add the endpoint_id."""
    if not endpoint_id:
        logger.error("Endpoint ID not set")
        return False

    logger.info("Updating FeatureFlagOverride {} to add endpoint: {}".format(FFO_NAME, endpoint_id))

    # 1. Verify kubectl access by getting the FFO
    out, ok = kubectl_cmd(
        "kubectl get featureflagoverride {} -n {} -o json".format(FFO_NAME, FFO_NAMESPACE))
    if not ok:
        logger.error("Cannot access cluster — ensure kubectl is configured and you are logged in")
        return False

    # 2. Parse current values
    try:
        ffo = json.loads(out)
        current_values = ffo['spec']['labelSelector']['matchExpressions'][0]['values']
        logger.info("Current endpoint values: {}".format(current_values))
    except (json.JSONDecodeError, KeyError, IndexError) as e:
        logger.error("Failed to parse FFO: {}".format(e))
        return False

    # 3. Check if endpoint_id already present
    if endpoint_id in current_values:
        logger.info("Endpoint {} already in FFO values — skipping patch".format(endpoint_id))
        return True

    # 4. Patch to add endpoint_id
    new_values = current_values + [endpoint_id]
    patch_json = json.dumps({
        "spec": {
            "labelSelector": {
                "matchExpressions": [{
                    "key": "endpoint_id",
                    "operator": "In",
                    "values": new_values
                }]
            }
        }
    })
    _, ok = kubectl_cmd(
        "kubectl patch featureflagoverride {} -n {} --type=merge -p '{}'".format(
            FFO_NAME, FFO_NAMESPACE, patch_json))
    if not ok:
        logger.error("Failed to patch FFO")
        return False

    # 5. Verify the patch
    out, ok = kubectl_cmd(
        "kubectl get featureflagoverride {} -n {} -o json".format(FFO_NAME, FFO_NAMESPACE))
    if ok:
        try:
            updated_values = json.loads(out)['spec']['labelSelector']['matchExpressions'][0]['values']
            if endpoint_id in updated_values:
                logger.info("FFO updated successfully — endpoint {} added".format(endpoint_id))
                logger.info("Updated endpoint values: {}".format(updated_values))
                return True
            else:
                logger.error("Endpoint {} not found in updated FFO values".format(endpoint_id))
                return False
        except (json.JSONDecodeError, KeyError, IndexError):
            pass

    logger.error("Failed to verify FFO update")
    return False


# ── Step 11: Wait for pod upgrade ────────────────────────────────────────────
def _parse_age_seconds(age_str):
    """Convert kubectl AGE string like '6h13m', '5m', '30s', '2d' to seconds."""
    total = 0
    num = ""
    for ch in age_str:
        if ch.isdigit():
            num += ch
        elif ch == 'd':
            total += int(num) * 86400; num = ""
        elif ch == 'h':
            total += int(num) * 3600; num = ""
        elif ch == 'm':
            total += int(num) * 60; num = ""
        elif ch == 's':
            total += int(num); num = ""
    return total


def wait_for_pod_upgrade(token):
    """Wait 5 min, then poll for dhcp- pods to be upgraded (age < 5 min). Retries up to 30 minutes."""
    if not endpoint_id:
        logger.error("Endpoint ID not set")
        return False

    logger.info("Waiting for pod upgrade in namespace {} for endpoint {}".format(POD_NAMESPACE, endpoint_id))

    # First verify kubectl cluster access
    _, cluster_ok = kubectl_cmd("kubectl get ns {} --no-headers".format(POD_NAMESPACE))
    if not cluster_ok:
        logger.error("Cannot access cluster — ensure kubectl is configured and logged in")
        return False
    logger.info("Cluster access verified")

    # Capture initial dhcp- pod names so we can detect when they change
    out_before, _ = kubectl_cmd(
        "kubectl get po -n {} --no-headers 2>/dev/null | grep 'dhcp-{}' || true".format(POD_NAMESPACE, endpoint_id))
    old_pods = set()
    for line in (out_before or "").splitlines():
        parts = line.split()
        if parts:
            old_pods.add(parts[0])
    logger.info("Current dhcp pods before upgrade: {}".format(old_pods if old_pods else "none"))

    # Wait 5 minutes for upgrade to start
    logger.info("Waiting 5 minutes for pod upgrade to begin...")
    time.sleep(300)

    max_attempts = 50  # 50 x 30s = 25 more minutes (total ~30 min)
    for attempt in range(1, max_attempts + 1):
        if attempt > 1:
            logger.info("Waiting 30s before checking pods (attempt {}/{})...".format(attempt, max_attempts))
            time.sleep(30)

        out, _ = kubectl_cmd(
            "kubectl get po -n {} --no-headers 2>/dev/null | grep 'dhcp-{}' || true".format(POD_NAMESPACE, endpoint_id))

        if not out:
            logger.info("No dhcp pods found for endpoint {} yet".format(endpoint_id))
            continue

        # Parse dhcp- pod lines
        dhcp_pods = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 5:
                # NAME  READY  STATUS  RESTARTS  AGE
                dhcp_pods.append({
                    "name": parts[0],
                    "ready": parts[1],
                    "status": parts[2],
                    "age_str": parts[4],
                    "age_sec": _parse_age_seconds(parts[4]),
                    "line": line.strip(),
                })

        if not dhcp_pods:
            logger.info("No dhcp pods parsed for endpoint {}".format(endpoint_id))
            continue

        logger.info("Current dhcp pods:")
        for p in dhcp_pods:
            logger.info("  {} (status={}, age={})".format(p["name"], p["status"], p["age_str"]))

        # Check if pods have been upgraded — either new pod names or young age (< 5 min)
        upgraded = []
        for p in dhcp_pods:
            if p["status"] == "Running":
                is_new_name = p["name"] not in old_pods
                is_young = p["age_sec"] < 300  # less than 5 minutes old
                if is_new_name or is_young:
                    upgraded.append(p)

        if upgraded:
            logger.info("Upgraded dhcp pod(s) detected:")
            for p in upgraded:
                logger.info("  {} (age={})".format(p["name"], p["age_str"]))
            # Check if all dhcp pods are now Running
            all_running = all(p["status"] == "Running" for p in dhcp_pods)
            if all_running:
                logger.info("All dhcp pods are Running after upgrade")
                return True
            else:
                logger.info("Some dhcp pods still not Running — waiting for all to come up")
                continue
        else:
            logger.info("No upgraded dhcp pods detected yet (all pods still have old names and age > 5 min)")

    logger.error("Pod upgrade not detected after 30 minutes")
    return False


# ── Step 12: Request DHCP lease (post-upgrade) ──────────────────────────────
def request_dhcp_lease_post_upgrade(token):
    """Run dras after upgrade to verify DHCP still works."""
    logger.info("Verifying DHCP lease after upgrade...")
    return request_dhcp_lease(token)


# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="DDIaaS DHCP Service Script")
    parser.add_argument("--no-cleanup", action="store_true", default=False,
                        help="Skip resource cleanup after run")
    args = parser.parse_args()

    token = CSP_API_TOKEN
    logger.info("Using API token for {} | WAN IP: {} | Region: {}".format(CSP_URL, WAN_IP, SERVICE_REGION))

    steps = [
        ("Create Universal Service + Infrastructure", create_universal_service_with_infra),
        ("Wait for DHCP service Available", wait_for_dhcp_available),
        ("Get endpoint cnames", get_endpoint_cnames),
        ("Create IP space", create_dhcp_ip_space),
        ("Create DHCP subnet", create_dhcp_subnet),
        ("Create DHCP range", create_dhcp_range),
        ("Get tunnel identities", get_tunnel_identities),
        ("Setup IPsec tunnels (pri + sec)", setup_ipsec_tunnel),
        ("Request DHCP lease (pre-upgrade, pri + sec)", request_dhcp_lease),
        ("Update FeatureFlagOverride", update_featureflag_override),
        ("Wait for pod upgrade", wait_for_pod_upgrade),
        ("Request DHCP lease (post-upgrade, pri + sec)", request_dhcp_lease_post_upgrade),
    ]

    results = []  # list of (step_name, "PASSED"/"FAILED")

    try:
        for step_name, step_func in steps:
            logger.info("=" * 60)
            logger.info("STEP: {}".format(step_name))
            logger.info("=" * 60)
            if not step_func(token):
                results.append((step_name, "FAILED"))
                logger.error("FAILED: {}".format(step_name))
                break
            results.append((step_name, "PASSED"))
            logger.info("PASSED: {}".format(step_name))
    finally:
        if args.no_cleanup:
            logger.info("Skipping cleanup (--no-cleanup)")
        else:
            cleanup(token)

        # Print summary
        logger.info("")
        logger.info("=" * 60)
        logger.info("EXECUTION SUMMARY")
        logger.info("=" * 60)
        if endpoint_id:
            logger.info("  Endpoint ID: {}".format(endpoint_id))
            logger.info("-" * 60)
        passed = 0
        failed = 0
        for i, (name, status) in enumerate(results, 1):
            icon = "PASS" if status == "PASSED" else "FAIL"
            logger.info("  Step {}: [{}] {}".format(i, icon, name))
            if status == "PASSED":
                passed += 1
            else:
                failed += 1
        # Mark remaining steps as skipped
        for i in range(len(results) + 1, len(steps) + 1):
            logger.info("  Step {}: [SKIP] {}".format(i, steps[i - 1][0]))
        logger.info("-" * 60)
        logger.info("  Total: {} passed, {} failed, {} skipped".format(
            passed, failed, len(steps) - len(results)))
        logger.info("=" * 60)

        if failed > 0:
            sys.exit(1)


if __name__ == "__main__":
    main()

