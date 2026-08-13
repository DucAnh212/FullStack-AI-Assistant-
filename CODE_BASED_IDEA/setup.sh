#!/bin/bash
set -e

echo "============================================"
echo "  FullStack AI Assistant - Auto Installer"
echo "============================================"

PROJECT_DIR=~/fullstack-ai-assistant
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

echo "1. Creating directory structure..."
mkdir -p config core tasks api dashboard tests data logs scripts

# Tạo file .env mẫu
cat > config/.env <<EOF
ANTHROPIC_API_KEY=sk-ant-placeholder
OPENAI_API_KEY=sk-placeholder
ENCRYPTION_KEY=$(python3 -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())")
EOF

# Tạo config.yaml
cat > config/config.yaml <<EOF
security:
  encryption_key: \${ENCRYPTION_KEY}
  api_keys:
    openai: \${OPENAI_API_KEY}
    anthropic: \${ANTHROPIC_API_KEY}
  rate_limit:
    max_requests_per_minute: 30
    max_tokens_per_request: 4000

models:
  primary: "claude-3-5-sonnet-20241022"
  fallback: "gpt-4-turbo-preview"

conversation:
  max_history: 50
  auto_save: true
  encryption: true

tasks:
  enabled:
    - debug
    - codereview
    - architecture
    - optimization
    - security
EOF

# Tạo requirements.txt
cat > requirements.txt <<EOF
fastapi==0.110.0
uvicorn[standard]==0.27.1
websockets==12.0
python-multipart==0.0.9
streamlit==1.33.0
anthropic==0.30.1
openai==1.30.1
cryptography==42.0.5
pyyaml==6.0.1
pydantic==2.6.4
pathspec==0.12.1
pytest==8.1.1
requests==2.31.0
EOF

echo "2. Creating Python source files..."

# ---------- core/security.py ----------
cat > core/security.py <<'EOF'
import os, re, base64, hashlib, logging
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes

class SecurityManager:
    def __init__(self, config):
        self.config = config
        self.logger = logging.getLogger(__name__)
        self.cipher = self._init_encryption()
        self.request_timestamps = []
        self.dangerous_patterns = [
            r'(?i)(DROP\s+TABLE|DELETE\s+FROM|UPDATE\s+.*SET)',
            r'(?i)(rm\s+-rf|sudo\s+rm|chmod\s+777)',
            r'(?i)(eval\(|exec\(|system\(|shell_exec\()',
            r'(?i)(<script>|javascript:|onerror=)',
        ]
    def _init_encryption(self):
        key = os.getenv('ENCRYPTION_KEY')
        if not key:
            key = base64.urlsafe_b64encode(os.urandom(32)).decode()
        kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=b'salt_', iterations=100000)
        derived = base64.urlsafe_b64encode(kdf.derive(key.encode()))
        return Fernet(derived)
    def encrypt_data(self, data): return self.cipher.encrypt(data.encode()).decode()
    def decrypt_data(self, data): return self.cipher.decrypt(data.encode()).decode()
    def sanitize_input(self, text):
        for p in self.dangerous_patterns:
            if re.search(p, text): return False, ""
        return True, re.sub(r'[<>\'"]', '', text)
    def sanitize_output(self, text):
        return re.sub(r'(?i)(api[_-]?key|secret)\s*[:=]\s*[\w\-]+', '[REDACTED]', text)
    def check_rate_limit(self):
        from datetime import datetime, timedelta
        now = datetime.now()
        self.request_timestamps = [t for t in self.request_timestamps if t > now - timedelta(minutes=1)]
        if len(self.request_timestamps) >= self.config['security']['rate_limit']['max_requests_per_minute']:
            return False
        self.request_timestamps.append(now)
        return True
EOF

# ---------- core/database.py ----------
cat > core/database.py <<'EOF'
import sqlite3, json, threading
from contextlib import contextmanager

class ConversationDB:
    _instance = None
    _lock = threading.Lock()
    def __new__(cls, db_path="data/conversations.db"):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super().__new__(cls)
                    cls._instance._init_db(db_path)
        return cls._instance
    def _init_db(self, db_path):
        self.db_path = db_path
        with self.get_connection() as conn:
            conn.execute("""CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY, title TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
            conn.execute("""CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT,
                role TEXT, content TEXT, encrypted_content TEXT, model_used TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
    @contextmanager
    def get_connection(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        try: yield conn; conn.commit()
        except: conn.rollback(); raise
        finally: conn.close()
    def create_conversation(self, cid, title="New"):
        with self.get_connection() as conn:
            conn.execute("INSERT INTO conversations (id, title) VALUES (?,?)", (cid, title))
    def save_message(self, cid, role, content, encrypted=None, model=None):
        with self.get_connection() as conn:
            conn.execute("INSERT INTO messages (conversation_id, role, content, encrypted_content, model_used) VALUES (?,?,?,?,?)",
                         (cid, role, content, encrypted, model))
    def get_history(self, cid, limit=50):
        with self.get_connection() as conn:
            cur = conn.execute("SELECT role, content, created_at FROM messages WHERE conversation_id=? ORDER BY created_at DESC LIMIT ?", (cid, limit))
            return [dict(r) for r in cur.fetchall()][::-1]
EOF

# ---------- core/reasoning.py ----------
cat > core/reasoning.py <<'EOF'
class ReasoningEngine:
    def __init__(self):
        pass
    def build_prompt(self, task_type, params, history=None):
        base = """### VÙNG 1: PHÂN VAI
Bạn là chuyên gia full-stack cấp cao. Nhiệm vụ: {task}.
### VÙNG 2: QUY TRÌNH SUY LUẬN 5 BƯỚC
1. Phân tích
2. Phát hiện mâu thuẫn
3. Tổng hợp
4. Phán quyết
5. Giải thích
### VÙNG 3: DỮ LIỆU
Vấn đề: {problem}
Mã nguồn: {code}
Ngữ cảnh: {context}
### VÙNG 4: BẮT ĐẦU SUY LUẬN
"""
        return base.format(task=task_type, problem=params.get('problem',''), code=params.get('code',''), context=params.get('context',''))
    def validate_reasoning(self, text):
        steps = ["Bước 1:", "Bước 2:", "Bước 3:", "Bước 4:", "Bước 5:"]
        return all(s in text for s in steps)
EOF

# ---------- core/assistant.py ----------
cat > core/assistant.py <<'EOF'
import os, yaml, uuid, logging
from core.security import SecurityManager
from core.database import ConversationDB
from core.reasoning import ReasoningEngine
import anthropic, openai

class FullStackAIAssistant:
    def __init__(self, config_path="config/config.yaml"):
        logging.basicConfig(level=logging.INFO)
        self.logger = logging.getLogger(__name__)
        with open(config_path) as f:
            self.config = yaml.safe_load(f)
        self.security = SecurityManager(self.config)
        self.db = ConversationDB()
        self.reasoning = ReasoningEngine()
        self.claude = anthropic.Anthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))
        openai.api_key = os.getenv("OPENAI_API_KEY")
        self.current_conv_id = None
    def process_task(self, task_type, params, user_id="default"):
        if not self.security.check_rate_limit():
            return {"success": False, "error": "Rate limit exceeded"}
        for k,v in params.items():
            if isinstance(v, str):
                ok, clean = self.security.sanitize_input(v)
                if not ok: return {"success": False, "error": f"Unsafe input in {k}"}
                params[k] = clean
        if not self.current_conv_id:
            self.current_conv_id = str(uuid.uuid4())
            self.db.create_conversation(self.current_conv_id, params.get('problem','')[:50])
        history = self.db.get_history(self.current_conv_id)
        system_prompt = self.reasoning.build_prompt(task_type, params, history)
        user_msg = f"Problem: {params.get('problem')}\nCode: {params.get('code')}\nContext: {params.get('context')}"
        encrypted_user = self.security.encrypt_data(user_msg)
        self.db.save_message(self.current_conv_id, "user", user_msg, encrypted_user)
        # Gọi AI
        try:
            if self.claude:
                resp = self.claude.messages.create(model=self.config['models']['primary'], max_tokens=2000, system=system_prompt, messages=[{"role":"user","content":user_msg}])
                ai_text = resp.content[0].text
            else:
                resp = openai.ChatCompletion.create(model=self.config['models']['fallback'], messages=[{"role":"system","content":system_prompt},{"role":"user","content":user_msg}])
                ai_text = resp.choices[0].message.content
        except Exception as e:
            return {"success": False, "error": str(e)}
        clean_text = self.security.sanitize_output(ai_text)
        encrypted_ai = self.security.encrypt_data(clean_text)
        self.db.save_message(self.current_conv_id, "assistant", clean_text, encrypted_ai, model=self.config['models']['primary'])
        return {"success": True, "response": clean_text, "conversation_id": self.current_conv_id}
EOF

# ---------- api/server.py ----------
cat > api/server.py <<'EOF'
import os, sys, json, logging
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from fastapi import FastAPI, WebSocket, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, validator
from core.assistant import FullStackAIAssistant
import uvicorn

app = FastAPI(title="FullStack AI Assistant")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
assistant = FullStackAIAssistant()

class TaskRequest(BaseModel):
    task_type: str
    problem: str
    code: str = ""
    context: str = ""
    conversation_id: str = None
    @validator('task_type')
    def validate_tt(cls, v):
        if v not in ['debug','codereview','architecture','optimization','security']:
            raise ValueError('Invalid task type')
        return v

@app.post("/api/v1/task")
async def handle_task(req: TaskRequest, request: Request):
    params = {"problem": req.problem, "code": req.code, "context": req.context}
    if req.conversation_id:
        assistant.current_conv_id = req.conversation_id
    result = assistant.process_task(req.task_type, params)
    if not result["success"]:
        raise HTTPException(400, result["error"])
    return result

@app.websocket("/ws/task")
async def ws_task(ws: WebSocket):
    await ws.accept()
    try:
        data = await ws.receive_json()
        params = {"problem": data.get("problem",""), "code": data.get("code",""), "context": data.get("context","")}
        result = assistant.process_task(data.get("task_type","debug"), params)
        if result["success"]:
            for line in result["response"].split('\n'):
                await ws.send_text(line + '\n')
        else:
            await ws.send_json({"error": result["error"]})
    except Exception as e:
        await ws.send_json({"error": str(e)})

@app.get("/health")
async def health(): return {"status": "ok"}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
EOF

# ---------- dashboard/app.py ----------
cat > dashboard/app.py <<'EOF'
import streamlit as st
import requests, json

st.set_page_config(page_title="AI Assistant", layout="wide")
st.title("🤖 FullStack AI Assistant")

with st.sidebar:
    model = st.selectbox("Model", ["claude-3-5-sonnet", "gpt-4-turbo"])
    uploaded_file = st.file_uploader("Upload project zip (context)", type="zip")
    if st.button("New Chat"):
        st.session_state.messages = []
        st.session_state.cid = None

if "messages" not in st.session_state:
    st.session_state.messages = []
if "cid" not in st.session_state:
    st.session_state.cid = None

for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])

task_type = st.selectbox("Task type", ["debug","codereview","architecture","optimization","security"])
problem = st.text_area("Problem / Code")
code = st.text_area("Code (optional)")
context = st.text_input("Context (e.g., tech stack)")

if st.button("Send") and problem:
    st.session_state.messages.append({"role":"user","content":problem})
    payload = {"task_type":task_type,"problem":problem,"code":code,"context":context}
    if st.session_state.cid:
        payload["conversation_id"] = st.session_state.cid
    with st.spinner("Thinking..."):
        try:
            r = requests.post("http://localhost:8000/api/v1/task", json=payload)
            if r.status_code==200:
                data = r.json()
                st.session_state.messages.append({"role":"assistant","content":data["response"]})
                st.session_state.cid = data.get("conversation_id")
            else:
                st.error(r.text)
        except Exception as e:
            st.error(str(e))
    st.rerun()
EOF

echo "3. Installing Python dependencies..."
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo "4. Initializing database..."
python -c "from core.database import ConversationDB; ConversationDB()"

echo "============================================"
echo " Installation completed successfully!"
echo " Next steps:"
echo "  1. Edit config/.env with your real API keys"
echo "  2. source venv/bin/activate"
echo "  3. Run server: uvicorn api.server:app --host 0.0.0.0 --port 8000"
echo "  4. Run dashboard (new terminal): streamlit run dashboard/app.py --server.port 8501 --server.address 0.0.0.0"


--for running:
chmod +x setup.sh
./setup.sh
echo "============================================"
EOF
