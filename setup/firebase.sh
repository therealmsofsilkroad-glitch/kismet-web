#!/usr/bin/env bash
# setup/firebase.sh
# Kismet sunucu kurulumu (Google Cloud Shell'de çalışır, kullanıcının kendi hesabıyla):
#   1) Gerekli API'leri açar (Firebase, FCM, Google Play Developer API)
#   2) Google Cloud projesine Firebase ekler, Android uygulamasını (app.kismetim) kaydeder
#   3) "kismet-sunucu" hizmet hesabını ve anahtarını oluşturur (FCM gönderme + Play doğrulama için)
#   4) Anahtarı ve Firebase istemci ayarlarını Kismet sunucusuna (Supabase) tek kullanımlık anahtarla doğrudan iletir.
# Anahtar sohbete ya da ekrana yazılmaz; Play ürünlerini kurmak için Cloud Shell'de ~/.kismet/key.json olarak kalır.
set -uo pipefail

P="${KISMET_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
P="${P:-kismetim}"
PKG="app.kismetim"
SA_NAME="kismet-sunucu"
SA="$SA_NAME@$P.iam.gserviceaccount.com"
DROP_URL="https://zkngjtsmsrkciywvigtd.supabase.co/rest/v1/rpc/setup_drop"
DROP_KEY="sb_publishable_TXYqa7qBfiVy7pj0M_Wq_Q_V4xNZjw_"
NONCE="6bd203b7-81d6-4409-a35b-791571b72886"
FB="https://firebase.googleapis.com/v1beta1"

say() { printf '\n\033[1;35m▶ %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m✖ %s\033[0m\n' "$*"; exit 1; }
api() { # api METHOD URL [BODY]
  local t; t=$(gcloud auth print-access-token 2>/dev/null) || fail "Google oturumu alınamadı."
  local args=(-sS -X "$1" "$2" -H "Authorization: Bearer $t" -H "X-Goog-User-Project: $P" -H "Content-Type: application/json")
  if [ $# -ge 3 ]; then args+=(-d "$3"); fi
  curl "${args[@]}"
}
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]) or '')" "$1" 2>/dev/null; }

say "Proje: $P"
gcloud config set project "$P" >/dev/null 2>&1 || fail "Proje seçilemedi: $P"

say "API'ler açılıyor (1-2 dk sürebilir)"
gcloud services enable firebase.googleapis.com fcm.googleapis.com fcmregistrations.googleapis.com \
  firebaseinstallations.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com \
  --project "$P" || fail "API'ler açılamadı (izin?)."
# Play Developer API sonda ayrıca açılır: koşullar kabul edilmemişse kurulum durmaz, bağlantı verilir.

say "Firebase ekleniyor"
if [ "$(api GET "$FB/projects/$P" | jget "d.get('projectId')")" != "$P" ]; then
  out=$(api POST "$FB/projects/$P:addFirebase" '{}')
  if echo "$out" | grep -q '"error"'; then
    echo "$out" | head -c 600; echo
    fail "Firebase eklenemedi. console.firebase.google.com'da bir kez 'Proje ekle' → mevcut '$P' projesini seçip koşulları kabul et, sonra betiği yeniden çalıştır."
  fi
  for i in $(seq 1 40); do
    [ "$(api GET "$FB/projects/$P" | jget "d.get('projectId')")" = "$P" ] && break
    sleep 3
  done
fi
echo "Firebase hazır."

say "Android uygulaması ($PKG)"
APP=$(api GET "$FB/projects/$P/androidApps" | jget "next((a['appId'] for a in d.get('apps',[]) if a.get('packageName')=='$PKG'), '')")
if [ -z "$APP" ]; then
  op=$(api POST "$FB/projects/$P/androidApps" "{\"packageName\":\"$PKG\",\"displayName\":\"Kismet\"}" | jget "d.get('name')")
  [ -n "$op" ] || fail "Android uygulaması oluşturulamadı."
  for i in $(seq 1 40); do
    APP=$(api GET "$FB/$op" | jget "d.get('response',{}).get('appId')")
    [ -n "$APP" ] && break
    sleep 3
  done
fi
[ -n "$APP" ] || fail "Android uygulamasının kimliği alınamadı."
CFG=$(api GET "$FB/projects/$P/androidApps/$APP/config" | jget "d.get('configFileContents')")
[ -n "$CFG" ] || fail "Firebase ayarları alınamadı."
echo "Uygulama: $APP"

say "Hizmet hesabı: $SA"
gcloud iam service-accounts describe "$SA" --project "$P" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$SA_NAME" --display-name="Kismet sunucu" --project "$P" || fail "Hizmet hesabı oluşturulamadı."
gcloud projects add-iam-policy-binding "$P" --member="serviceAccount:$SA" \
  --role="roles/firebasecloudmessaging.admin" --condition=None >/dev/null || fail "FCM yetkisi verilemedi."
mkdir -p ~/.kismet && chmod 700 ~/.kismet
KEY_NEW=0
if [ ! -s ~/.kismet/key.json ]; then
  KEY_NEW=1
  gcloud iam service-accounts keys create ~/.kismet/key.json --iam-account="$SA" --project "$P" \
    || fail "Anahtar oluşturulamadı (kuruluş politikası anahtarı engelliyor olabilir)."
fi
chmod 600 ~/.kismet/key.json

say "Kismet sunucusuna iletiliyor"
res=$(CFG="$CFG" python3 - "$DROP_URL" "$DROP_KEY" "$NONCE" "$P" "$APP" "$SA" <<'PY'
import base64, json, os, sys, urllib.request
url, key, nonce, project, app, sa = sys.argv[1:7]
g = json.loads(base64.b64decode(os.environ["CFG"]))
client = g["client"][0]
fb = {
    "project_id": g["project_info"]["project_id"],
    "sender_id": g["project_info"]["project_number"],
    "app_id": client["client_info"]["mobilesdk_app_id"],
    "api_key": client["api_key"][0]["current_key"],
}
body = json.dumps({"p_nonce": nonce, "p_payload": {
    "firebase": fb, "service_account": json.load(open(os.path.expanduser("~/.kismet/key.json"))), "sa_email": sa,
}}).encode()
req = urllib.request.Request(url, data=body, method="POST", headers={"apikey": key, "Content-Type": "application/json"})
try:
    print(json.loads(urllib.request.urlopen(req, timeout=30).read().decode()))
except Exception as e:
    print("hata:", e)
PY
)
if [ "$res" != "ok" ]; then
  if [ "$KEY_NEW" = 0 ] && [ "$res" = "expired" ]; then
    echo "Anahtar daha önce iletilmişti."
  else
    fail "İletilemedi: $res (anahtarın süresi dolduysa Claude'dan yenisini iste)."
  fi
fi

say "Google Play Developer API"
if gcloud services enable androidpublisher.googleapis.com --project "$P" >/dev/null 2>&1; then
  PLAY_API=ok
  echo "Açık."
else
  PLAY_API=no
fi

printf '\n\033[1;32m✔ Tamam! Claude'"'"'a "betik bitti" yaz.\033[0m\n'
printf '\nPlay Console'"'"'a davet edilecek hizmet hesabı:\n\n   \033[1m%s\033[0m\n\n' "$SA"
if [ "$PLAY_API" = no ]; then
  ACC=$(gcloud config get-value account 2>/dev/null)
  printf '\033[1;33m! Google Play Developer API için kullanım koşullarını bir kez kabul etmen gerekiyor.\033[0m\n'
  printf '  1) Şu bağlantıya dokun (bu hesapla açılır):\n     https://console.developers.google.com/terms/androidpublisher?authuser=%s\n' "$ACC"
  printf '  2) Kabul et, sonra bu komutu tekrar çalıştır:  curl -sL kismetim.app/k | bash\n\n'
else
  printf '\033[1;32m✔ Google Play Developer API açık.\033[0m\n\n'
fi
