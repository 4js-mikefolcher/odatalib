#!/usr/bin/env bash
#
# gas_encoding_test.sh - GAS-level check that percent-encoded query option
# names (%24top) are accepted exactly like the plain ones ($top).
#
# GAS (GWS) matches a query parameter NAME literally against the WSName declared
# on the REST function and answers "400 Unexpected Rest query parameter" (empty
# body) before odatalib is called, so this class of defect is invisible to the
# in-memory suite (`make test`). This script needs a running service.
#
# Usage:
#   ODATA_URL=http://localhost/gas6/ws/r/<xcf>/<service> \
#       tests/gas_encoding_test.sh
#
#   ODATA_URL            root of an already-running service (required), no
#                        trailing slash needed
#   ODATA_PROFILE        which dataset the service serves:
#                          northwind (default)  examples/northwind-pg.odata
#                          adventureworks       examples/adventureworks.odata
#   ODATA_CURL_OPTS      extra curl arguments, e.g. "-u user:password"
#
# Target a PostgreSQL example service without an authorizer. It is not valid
# against the in-memory SQLite example (examples/NorthwindService): northwind.odata
# has no ShipCountry (checks 6, 8, 10b get 400) and NorthwindAuth answers 401 to the
# inner $batch request. Those four checks fail the same way on every Genero version.
#
# For every case the encoded request and the plain "$" request must both return
# 200 with byte-identical bodies. Unknown options must still return 400 (the
# endpoints must not turn into "accept any parameter"). The script exits
# non-zero if any check fails.
#
# Needs: bash, curl, python3 (only to read JSON).

set -u

: "${ODATA_URL:?set ODATA_URL to the service root, e.g. http://localhost/gas6/ws/r/<xcf>/<service>}"
BASE=${ODATA_URL%/}
PROFILE=${ODATA_PROFILE:-northwind}
CURL_OPTS=${ODATA_CURL_OPTS:-}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; }

# get <path> <outfile>  -> prints the HTTP status
get() {
    # shellcheck disable=SC2086
    curl -s -g --max-time 60 $CURL_OPTS -o "$2" -w '%{http_code}' "$BASE/$1"
}

# post_batch <json> <outfile>  -> prints the HTTP status
post_batch() {
    # shellcheck disable=SC2086
    curl -s -g --max-time 60 $CURL_OPTS -o "$2" -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' -d "$1" "$BASE/\$batch"
}

# json_eval <file> <python expression over d>  -> prints the value
json_eval() {
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null
}

# pair <label> <plain path> <encoded path>
# Both forms must return 200 and the same non-empty body.
pair() {
    local label=$1 plain=$2 enc=$3 sp se
    sp=$(get "$plain" "$TMP/plain")
    se=$(get "$enc" "$TMP/enc")
    if [ "$sp" != 200 ]; then
        fail "$label - the plain form returned $sp (check the dataset): $plain"
    elif [ "$se" != 200 ]; then
        fail "$label - the encoded form returned $se: $enc"
    elif [ ! -s "$TMP/plain" ]; then
        fail "$label - empty body (nothing to compare): $plain"
    elif ! cmp -s "$TMP/plain" "$TMP/enc"; then
        fail "$label - the bodies differ: $enc"
    else
        pass "$label"
    fi
}

# expect_status <label> <path> <status>
expect_status() {
    local label=$1 path=$2 want=$3 got
    got=$(get "$path" "$TMP/out")
    if [ "$got" = "$want" ]; then
        pass "$label (HTTP $got)"
    else
        fail "$label - expected HTTP $want, got $got: $path"
    fi
}

# --- datasets ----------------------------------------------------------------
# Each row is: label | plain path | encoded path. Spaces are always %20 (curl
# would send a raw space in the request line, which GAS drops).

case $PROFILE in
northwind)
    ENTITY=Customers
    CASES=(
'1 getEntitySet $top|Customers?$top=2|Customers?%24top=2'
'2 getEntitySet $select+$top|Customers?$select=CustomerID%2CCompanyName&$top=2|Customers?%24select=CustomerID%2CCompanyName&%24top=2'
'3 getEntitySet $filter+$count|Customers?$filter=Country%20eq%20%27Germany%27&$count=true|Customers?%24filter=Country%20eq%20%27Germany%27&%24count=true'
'4 getEntitySet $orderby+$top+$skip|Orders?$orderby=OrderID%20desc&$top=1&$skip=1|Orders?%24orderby=OrderID%20desc&%24top=1&%24skip=1'
'5 key request $expand|Orders(10248)?$expand=Customer|Orders(10248)?%24expand=Customer'
'6 getEntitySet $apply|Orders?$apply=groupby((ShipCountry),aggregate($count%20as%20N))|Orders?%24apply=groupby((ShipCountry),aggregate(%24count%20as%20N))'
'7 getNavigation $top|Customers('"'"'ALFKI'"'"')/Orders?$top=2|Customers('"'"'ALFKI'"'"')/Orders?%24top=2'
'8 getEntityCount $filter|Orders/$count?$filter=ShipCountry%20eq%20%27France%27|Orders/$count?%24filter=ShipCountry%20eq%20%27France%27'
'9 mixed forms (R2)|Customers?$top=2&$select=CustomerID|Customers?$top=2&%24select=CustomerID'
'10 fully percent-encoded (R2)|Customers?$filter=Country%20eq%20%27Germany%27&$select=CustomerID,CompanyName&$orderby=CustomerID%20desc&$top=3&$count=true|Customers?%24filter=Country%20eq%20%27Germany%27&%24select=CustomerID%2CCompanyName&%24orderby=CustomerID%20desc&%24top=3&%24count=true'
'10b fully percent-encoded $apply (R2)|Orders?$apply=groupby((ShipCountry),aggregate($count%20as%20N))|Orders?%24apply=groupby%28%28ShipCountry%29%2Caggregate%28%24count%20as%20N%29%29'
    )
    BATCH_URL='Customers?$top=2&$select=CustomerID'
    BATCH_ENC_URL='Customers?%24top=2&%24select=CustomerID'
    ;;
adventureworks)
    ENTITY=Customers
    CASES=(
'1 getEntitySet $top|Customers?$top=2|Customers?%24top=2'
'2 getEntitySet $select+$top|SalesOrders?$select=SalesOrderID%2CCustomerID&$top=2|SalesOrders?%24select=SalesOrderID%2CCustomerID&%24top=2'
'3 getEntitySet $filter+$count|SalesTerritories?$filter=CountryRegionCode%20eq%20%27US%27&$count=true|SalesTerritories?%24filter=CountryRegionCode%20eq%20%27US%27&%24count=true'
'4 getEntitySet $orderby+$top+$skip|SalesOrders?$orderby=SalesOrderID%20desc&$top=1&$skip=1|SalesOrders?%24orderby=SalesOrderID%20desc&%24top=1&%24skip=1'
'5 key request $expand|SalesOrders(43659)?$expand=Customer|SalesOrders(43659)?%24expand=Customer'
'6 getEntitySet $apply|SalesOrders?$apply=groupby((TerritoryID),aggregate($count%20as%20N))|SalesOrders?%24apply=groupby((TerritoryID),aggregate(%24count%20as%20N))'
'7 getNavigation $top|Customers(11000)/Orders?$top=2|Customers(11000)/Orders?%24top=2'
'8 getEntityCount $filter|SalesOrders/$count?$filter=TerritoryID%20eq%201|SalesOrders/$count?%24filter=TerritoryID%20eq%201'
'9 mixed forms (R2)|Customers?$top=2&$select=CustomerID|Customers?$top=2&%24select=CustomerID'
'10 fully percent-encoded (R2)|SalesTerritories?$filter=CountryRegionCode%20eq%20%27US%27&$select=TerritoryID,Name&$orderby=TerritoryID%20desc&$top=3&$count=true|SalesTerritories?%24filter=CountryRegionCode%20eq%20%27US%27&%24select=TerritoryID%2CName&%24orderby=TerritoryID%20desc&%24top=3&%24count=true'
'10b fully percent-encoded $apply (R2)|SalesOrders?$apply=groupby((TerritoryID),aggregate($count%20as%20N))|SalesOrders?%24apply=groupby%28%28TerritoryID%29%2Caggregate%28%24count%20as%20N%29%29'
    )
    BATCH_URL='Customers?$top=2&$select=CustomerID'
    BATCH_ENC_URL='Customers?%24top=2&%24select=CustomerID'
    ;;
*)
    echo "unknown ODATA_PROFILE '$PROFILE' (want northwind|adventureworks)" >&2
    exit 2
    ;;
esac

echo "gas_encoding_test: $BASE (profile: $PROFILE)"

# --- R1 / R2: encoded equals plain --------------------------------------------
echo "encoded vs plain (R1, R2):"
for row in "${CASES[@]}"; do
    IFS='|' read -r label plain enc <<<"$row"
    pair "$label" "$plain" "$enc"
done

# --- R4: both spellings of one option -----------------------------------------
# The "$" form wins; no error. (GWS itself rejects a repeated *identical* name.)
echo "both spellings of one option (R4):"
st=$(get "$ENTITY?\$top=1&%24top=2" "$TMP/both")
rows=$(json_eval "$TMP/both" 'len(d["value"])')
if [ "$st" = 200 ] && [ "$rows" = 1 ]; then
    pass "\$top=1 and %24top=2 together -> 1 row (the \$ form wins)"
else
    fail "\$top=1&%24top=2 expected HTTP 200 with 1 row, got HTTP $st with rows='$rows'"
fi
st=$(get "$ENTITY?%24top=1&\$top=2" "$TMP/both2")
rows=$(json_eval "$TMP/both2" 'len(d["value"])')
if [ "$st" = 200 ] && [ "$rows" = 2 ]; then
    pass "%24top=1 and \$top=2 together -> 2 rows (order in the URL does not matter)"
else
    fail "%24top=1&\$top=2 expected HTTP 200 with 2 rows, got HTTP $st with rows='$rows'"
fi

# --- R5: unknown options are still rejected -----------------------------------
echo "unknown options are still rejected (R5):"
expect_status "unknown encoded option %24bogus" "$ENTITY?%24bogus=1" 400
expect_status "unknown plain option foo" "$ENTITY?foo=1" 400
expect_status "known alias next to an unknown name" "$ENTITY?%24top=1&%24bogus=1" 400

# --- R6: $batch sub-URLs (parsed by the library itself) ------------------------
echo "\$batch sub-request URL (R6):"
body_plain='{"requests":[{"id":"1","method":"GET","url":"'"$BATCH_URL"'"}]}'
body_enc='{"requests":[{"id":"1","method":"GET","url":"'"$BATCH_ENC_URL"'"}]}'
sp=$(post_batch "$body_plain" "$TMP/bplain")
se=$(post_batch "$body_enc" "$TMP/benc")
inner=$(json_eval "$TMP/benc" 'd["responses"][0]["status"]')
brows=$(json_eval "$TMP/benc" 'len(d["responses"][0]["body"]["value"])')
if [ "$sp" != 200 ] || [ "$se" != 200 ]; then
    fail "batch HTTP status plain=$sp encoded=$se"
elif [ "$inner" != 200 ] || [ "$brows" != 2 ]; then
    fail "batch inner status=$inner rows=$brows (want 200 and 2)"
elif ! cmp -s "$TMP/bplain" "$TMP/benc"; then
    fail "batch bodies differ between the plain and the encoded sub-URL"
else
    pass "batch sub-URL $BATCH_ENC_URL -> inner 200, 2 rows, identical to the plain form"
fi

echo
echo "==== gas_encoding_test: $PASSED passed, $FAILED failed ===="
[ "$FAILED" -eq 0 ]
