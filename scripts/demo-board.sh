#!/usr/bin/env bash
# Builds the "Commonplace Demo" board used for the README screenshots, through the
# app's MCP server (the app must be running). Usage: scripts/demo-board.sh
set -euo pipefail
TOKEN=$(cat ~/Commonplace/.mcp-token)
BOARD="Commonplace Demo"

call() {  # call <tool> <json arguments> → prints the new card id (or board name)
  local body
  body=$(python3 -c "import json,sys; print(json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':sys.argv[1],'arguments':json.loads(sys.argv[2])}}))" "$1" "$2")
  curl -s -X POST http://127.0.0.1:7717/mcp -H "Authorization: Bearer $TOKEN" -d "$body" |
    python3 -c "import json,sys; r=json.load(sys.stdin)['result']; t=r['content'][0]['text']; sys.exit('error: '+t) if r['isError'] else print(json.loads(t).get('card',{}).get('id') or json.loads(t).get('board',''))"
}
b() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['board']='$BOARD'; print(json.dumps(d))" "$1"; }

call create_board "{\"name\":\"$BOARD\"}" >/dev/null
Q=$(call add_card "$(b '{"kind":"note","title":"What should onboarding teach first?","body":"New people leave in their first session.\nWhat'"'"'s the **one idea** they need before anything else?","x":0,"y":0,"color":"blue"}')")
T1=$(call add_thought "$(b "{\"card_id\":\"$Q\",\"body\":\"Show a finished board before an empty one\"}")")
T2=$(call add_thought "$(b "{\"card_id\":\"$Q\",\"body\":\"Teach one shortcut: **T** for a thought\"}")")
T3=$(call add_thought "$(b "{\"card_id\":\"$Q\",\"body\":\"Let them bring in something they already care about\"}")")
call add_thought "$(b "{\"card_id\":\"$T2\",\"body\":\"Everything else can wait until they ask\"}")" >/dev/null
SU=$(call clip_url "$(b '{"url":"https://basecamp.com/shapeup"}')")
ZK=$(call clip_url "$(b '{"url":"https://en.wikipedia.org/wiki/Zettelkasten"}')")
call update_card "$(b "{\"card_id\":\"$SU\",\"x\":-390,\"y\":-40}")" >/dev/null
call update_card "$(b "{\"card_id\":\"$ZK\",\"x\":-390,\"y\":300,\"height\":240}")" >/dev/null
call add_reference "$(b "{\"from\":\"$SU\",\"to\":\"$Q\",\"label\":\"shaped with\"}")" >/dev/null
call add_reference "$(b "{\"from\":\"$T2\",\"to\":\"$ZK\",\"label\":\"like a Folgezettel\"}")" >/dev/null
call add_reference "$(b "{\"from\":\"$T3\",\"to\":\"$SU\",\"label\":\"fits the appetite\"}")" >/dev/null
W=$(call add_card "$(b '{"kind":"place","title":"Welcome","body":"Open the sample board\nStart empty","x":0,"y":620}')")
SB=$(call add_card "$(b '{"kind":"place","title":"Sample board","body":"Press T on a card\nPaste a link","x":320,"y":560}')")
EB=$(call add_card "$(b '{"kind":"place","title":"Empty board","body":"Paste a link","x":320,"y":740}')")
call add_reference "$(b "{\"from\":\"$W\",\"to\":\"$SB\",\"from_affordance\":\"Open the sample board\"}")" >/dev/null
call add_reference "$(b "{\"from\":\"$W\",\"to\":\"$EB\",\"from_affordance\":\"Start empty\"}")" >/dev/null
call add_reference "$(b "{\"from\":\"$T1\",\"to\":\"$SB\",\"label\":\"sketched in\"}")" >/dev/null
# Big Buck Bunny (c) Blender Foundation, CC BY 3.0.
V=$(call clip_url "$(b '{"url":"https://www.youtube.com/watch?v=aqz-KE-bpKQ"}')")
call update_card "$(b "{\"card_id\":\"$V\",\"x\":700,\"y\":560}")" >/dev/null
for t in "20|Open on a calm world before any conflict" "95|The problem arrives in one clear beat" \
         "250|Small setups pay off later: keep onboarding promises small"; do
  call add_thought "$(b "{\"card_id\":\"$V\",\"timestamp\":${t%%|*},\"body\":\"${t#*|}\"}")" >/dev/null
done
call tidy_thread "$(b "{\"card_id\":\"$Q\"}")" >/dev/null
call tidy_thread "$(b "{\"card_id\":\"$V\"}")" >/dev/null
echo "Built \"$BOARD\". Open it in Commonplace and press F to fit."
