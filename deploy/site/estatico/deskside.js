// O pouco de comportamento do site do Deskside (só a página inicial):
// escolhe o botão pelo sistema de quem visita, troca as abas e o processador
// do Linux, copia os comandos, e anima o dedo e o cursor da abertura.
// Sem nada disso a página funciona: o botão baixa o do Windows e a aba do
// Windows fica aberta.
(function () {
  // ---- o sistema de quem visita escolhe o botão e a aba ----
  var SISTEMAS = {
    windows: { rotulo: "Baixar para Windows", arquivo: "/baixar/Deskside.exe", req: "Windows 10 ou 11 · Intel, AMD ou ARM · sem precisar de administrador" },
    // Sem download até o primeiro teste num Mac de verdade (docs/agente-mac.md).
    mac: { rotulo: "Mac: em breve", arquivo: "#baixar", req: "Por enquanto, Windows e Linux. O Mac está em teste." },
    linux: { rotulo: "Baixar para Linux", arquivo: "/baixar/Deskside-linux-x86_64.tar.gz", req: "x86_64 ou aarch64 · Wayland ou X11 · sem precisar de administrador" }
  };
  function detectar() {
    var p = ((navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "") + " " + navigator.userAgent;
    if (/Android|iPhone|iPad/i.test(p)) return null;
    if (/Mac/i.test(p)) return "mac";
    if (/Linux|X11|CrOS/i.test(p)) return "linux";
    return "windows";
  }
  function abrirAba(nome) {
    document.querySelectorAll('[role="tab"]').forEach(function (t) {
      var sim = t.dataset.sistema === nome;
      t.setAttribute("aria-selected", sim ? "true" : "false");
      t.tabIndex = sim ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).hidden = !sim;
    });
  }
  var meu = detectar();
  if (meu) {
    var s = SISTEMAS[meu];
    document.getElementById("rotulo-principal").textContent = s.rotulo;
    document.getElementById("botao-principal").href = s.arquivo;
    document.getElementById("requisitos-principal").textContent = s.req;
    abrirAba(meu);
    // Ao lado do botão, os outros sistemas.
    var alvo = document.getElementById("outros");
    function link(k, nome) {
      var a = document.createElement("a");
      a.href = "#baixar"; a.dataset.ir = k; a.textContent = nome;
      return a;
    }
    alvo.textContent = "";
    if (meu === "mac") {
      alvo.append("Disponível para ", link("windows", "Windows"), " e ", link("linux", "Linux"));
    } else if (meu === "linux") {
      alvo.append("Também para ", link("windows", "Windows"), " · Mac em breve");
    } else {
      alvo.append("Também para ", link("linux", "Linux"), " · Mac em breve");
    }
  }
  var abas = Array.prototype.slice.call(document.querySelectorAll('[role="tab"]'));
  abas.forEach(function (t, i) {
    t.addEventListener("click", function () { abrirAba(t.dataset.sistema); });
    t.addEventListener("keydown", function (e) {
      var d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
      if (!d) return;
      var prox = abas[(i + d + abas.length) % abas.length];
      abrirAba(prox.dataset.sistema); prox.focus();
    });
  });
  document.querySelectorAll("[data-ir]").forEach(function (a) {
    a.addEventListener("click", function () { abrirAba(a.dataset.ir); });
  });

  // ---- Linux: o processador troca o arquivo e os comandos ----
  var arq = "x86_64";
  function linhas() {
    return ["tar xzf Deskside-linux-" + arq + ".tar.gz", "cd deskside", "./deskside-agent install"];
  }
  function trocarArq(novo) {
    arq = novo;
    document.querySelectorAll("[data-arq]").forEach(function (b) { b.setAttribute("aria-pressed", b.dataset.arq === arq ? "true" : "false"); });
    var link = document.getElementById("baixar-linux");
    link.href = "/baixar/Deskside-linux-" + arq + ".tar.gz";
    link.textContent = "Deskside-linux-" + arq + ".tar.gz";
    var pre = document.getElementById("comandos");
    pre.textContent = "";
    linhas().forEach(function (l, i) {
      var p = document.createElement("span"); p.textContent = "$ "; pre.appendChild(p);
      pre.appendChild(document.createTextNode(l + (i < 2 ? "\n" : "")));
    });
  }
  document.querySelectorAll("[data-arq]").forEach(function (b) { b.addEventListener("click", function () { trocarArq(b.dataset.arq); }); });
  document.getElementById("copiar").addEventListener("click", function () {
    var botao = this, texto = linhas().join(" && ");
    function feito() { botao.textContent = "copiado"; setTimeout(function () { botao.textContent = "copiar"; }, 1600); }
    function manual() {
      var r = document.createRange(); r.selectNodeContents(document.getElementById("comandos"));
      var sel = getSelection(); sel.removeAllRanges(); sel.addRange(r);
      botao.textContent = "Ctrl+C para copiar";
    }
    if (navigator.clipboard) navigator.clipboard.writeText(texto).then(feito, manual); else manual();
  });

  // ---- o relógio da barra de tarefas é a hora de quem visita ----
  function hora() {
    var d = new Date();
    document.getElementById("relogio").textContent = String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
  }
  hora(); setInterval(hora, 20000);

  // ---- o dedo no touchpad move o cursor no monitor ----
  var tela = document.getElementById("tela"), pad = document.getElementById("touchpad");
  var cursor = document.getElementById("cursor"), dedo = document.getElementById("dedo"), onda = document.getElementById("onda");
  var parado = matchMedia("(prefers-reduced-motion: reduce)").matches;
  function posicao(t) {
    return {
      x: 0.5 + 0.30 * Math.sin(t * 0.55) + 0.08 * Math.sin(t * 1.7),
      y: 0.48 + 0.24 * Math.sin(t * 0.8 + 1.2) + 0.05 * Math.cos(t * 2.1)
    };
  }
  function desenhar(t) {
    var p = posicao(t);
    var W = tela.clientWidth, H = tela.clientHeight, w = pad.clientWidth, h = pad.clientHeight;
    cursor.style.transform = "translate(" + (p.x * W) + "px," + (p.y * H) + "px)";
    dedo.style.transform = "translate(" + (p.x * w) + "px," + (p.y * h) + "px)";
    return { x: p.x * W, y: p.y * H };
  }
  if (parado) { desenhar(1.1); return; }
  var inicio = performance.now(), ultimoToque = 0;
  function quadro(agora) {
    var t = (agora - inicio) / 1000;
    var c = desenhar(t);
    if (t - ultimoToque > 3.6) {
      ultimoToque = t;
      onda.style.setProperty("--pos", "translate(" + c.x + "px," + c.y + "px)");
      onda.style.transform = "translate(" + c.x + "px," + c.y + "px)";
      onda.classList.remove("tocou"); void onda.offsetWidth; onda.classList.add("tocou");
    }
    requestAnimationFrame(quadro);
  }
  requestAnimationFrame(quadro);
})();
