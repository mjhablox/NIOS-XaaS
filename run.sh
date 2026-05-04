#!/bin/bash
source .venv/bin/activate

#joint token env-2a: dXMtZGV2LTI.IxdQqkLyQaXenxzLYr08OuCGszkdGvNsp7rvp0GM0cDg.ibjt
create_endpoint () {
#    CSP_URL="stage.csp.infoblox.com" CSP_API_TOKEN="7be62b45741a02d96eca65365b1605709dfea81c14168fbf7979722f3f390003" python3 create_endpoint.py  --no-cleanup
    CSP_URL="env-2a.test.infoblox.com" CSP_API_TOKEN="526545a50fd96b13bdce68b0816064d2ee7ea940c0da33e6185dd5671c37355e" python3 create_endpoint.py  --no-cleanup
}

create_endpoint 2>&1 | tee log_env2a.txt
