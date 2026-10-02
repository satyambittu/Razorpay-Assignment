.PHONY: test demo spec mock
test:  ; python3 -m unittest -v
demo:  ; python3 scripts/demo.py
spec:  ; python3 -m wc_connector spec --out docs/mcp_tools.json
mock:  ; python3 -m mock_wc --port 8099
