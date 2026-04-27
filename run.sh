#!/bin/bash
source .venv/bin/activate

create_endpoint () {
    CSP_URL="stage.csp.infoblox.com" CSP_API_TOKEN="7be62b45741a02d96eca65365b1605709dfea81c14168fbf7979722f3f390003" python3 create_endpoint.py  --no-cleanup
}

create_endpoint | tee log.txt
