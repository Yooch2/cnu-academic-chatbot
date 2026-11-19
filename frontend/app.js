const API = window.API_BASE_URL; // config.js (배포할 때 생성)

async function checkHealth() {
  const el = document.getElementById("health");
  try {
    const res = await fetch(`${API}/health`);
    const data = await res.json();
    el.textContent = `API 연결 정상 (GET /health → ${res.status} ${data.status})`;
    el.classList.add("ok");
  } catch (e) {
    el.textContent = "API에 연결하지 못했습니다.";
    el.classList.add("fail");
  }
}

async function ask(question) {
  const res = await fetch(`${API}/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ question }),
  });
  const data = await res.json();
  document.getElementById("answer").textContent = data.answer || data.error;
  const list = document.getElementById("sources");
  list.innerHTML = "";
  (data.sources || []).forEach((s) => {
    const li = document.createElement("li");
    li.innerHTML = `<a href="${s.url}" target="_blank">${s.title}</a> <span>(${s.date})</span>`;
    list.appendChild(li);
  });
  if (!data.sources || data.sources.length === 0) {
    list.innerHTML = "<li>근거 문서 없음</li>";
  }
  document.getElementById("result").hidden = false;
}

document.getElementById("chat-form").addEventListener("submit", (e) => {
  e.preventDefault();
  ask(document.getElementById("question").value);
});

document.querySelectorAll(".examples button").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.getElementById("question").value = btn.dataset.q;
    ask(btn.dataset.q);
  });
});

checkHealth();

// 주소에 ?q=질문 이 있으면 바로 물어본다 (질문 링크 공유용)
const sharedQ = new URLSearchParams(location.search).get("q");
if (sharedQ) {
  document.getElementById("question").value = sharedQ;
  ask(sharedQ);
}
