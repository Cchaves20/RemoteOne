// O pouco de comportamento do site do Deskside (só a página inicial):
// escolhe o botão pelo sistema de quem visita (e, no celular, troca o botão
// por "abra no computador"), troca as abas e o processador do Linux, copia
// os comandos e anima o dedo e o cursor da abertura.
// Sem script a página funciona: o botão baixa o do Windows e os três
// painéis de download aparecem um embaixo do outro.
(function () {
  var SISTEMAS = {
    windows: { rotulo: "Baixar para Windows", arquivo: "/baixar/Deskside.exe", req: "Windows 10 ou 11 · Intel, AMD ou ARM · sem precisar de administrador" },
    linux: { rotulo: "Baixar para Linux", arquivo: "/baixar/Deskside-linux-x86_64.tar.gz", req: "Intel, AMD ou ARM · Wayland ou X11 · sem precisar de administrador" },
    mac: { rotulo: "Baixar para Mac", arquivo: "/baixar/Deskside.dmg", req: "macOS 13 ou mais novo · chip Apple ou Intel · sem precisar de administrador" }
  };
  function detectar() {
    var p = ((navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "") + " " + navigator.userAgent;
    if (/Android|iPhone|iPad|iPod/i.test(p) || (/Mac/.test(p) && navigator.maxTouchPoints > 1)) return "celular";
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
  function link(k, nome) { var a = document.createElement("a"); a.href = "#baixar"; a.dataset.ir = k; a.textContent = nome; return a; }

  var meu = detectar();
  if (meu === "celular") {
    // No celular, baixar o instalador não serve para nada: o que serve é
    // levar o endereço para o computador.
    document.getElementById("acoes-computador").hidden = true;
    document.getElementById("requisitos-principal").hidden = true;
    document.getElementById("no-celular").hidden = false;
    // Na seção de baixar também: o aviso no alto, e os botões de download
    // sem destaque (continuam lá para quem quiser o link).
    document.getElementById("aviso-celular").hidden = false;
    document.body.classList.add("no-celular-visitando");
  } else {
    var s = SISTEMAS[meu];
    document.getElementById("rotulo-principal").textContent = s.rotulo;
    document.getElementById("botao-principal").href = s.arquivo;
    document.getElementById("requisitos-principal").textContent = s.req;
    abrirAba(meu);
    var alvo = document.getElementById("outros");
    alvo.textContent = "";
    var NOMES = { windows: "Windows", mac: "Mac", linux: "Linux" };
    var outros = ["windows", "mac", "linux"].filter(function (k) { return k !== meu; });
    alvo.append("Também para ", link(outros[0], NOMES[outros[0]]), " e ", link(outros[1], NOMES[outros[1]]));
  }
  document.querySelectorAll(".copiar-endereco").forEach(function (b) {
    b.addEventListener("click", function () {
      function ok() { b.textContent = "Endereço copiado"; }
      if (navigator.clipboard) navigator.clipboard.writeText("https://deskside.com.br").then(ok, function () {});
    });
  });

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
  document.addEventListener("click", function (e) {
    var a = e.target.closest && e.target.closest("[data-ir]");
    if (a) abrirAba(a.dataset.ir);
  });

  // ---- Linux: o processador troca o arquivo e os comandos ----
  var arq = "x86_64";
  function linhas() { return ["tar xzf Deskside-linux-" + arq + ".tar.gz", "cd deskside", "./deskside-agent install"]; }
  document.querySelectorAll("[data-arq]").forEach(function (b) {
    b.addEventListener("click", function () {
      arq = b.dataset.arq;
      document.querySelectorAll("[data-arq]").forEach(function (x) { x.setAttribute("aria-pressed", x === b ? "true" : "false"); });
      var l = document.getElementById("baixar-linux");
      l.href = "/baixar/Deskside-linux-" + arq + ".tar.gz"; l.textContent = "Deskside-linux-" + arq + ".tar.gz";
      var pre = document.getElementById("comandos"); pre.textContent = "";
      linhas().forEach(function (t, i) {
        var p = document.createElement("span"); p.textContent = "$ "; pre.appendChild(p);
        pre.appendChild(document.createTextNode(t + (i < 2 ? "\n" : "")));
      });
    });
  });
  document.getElementById("copiar").addEventListener("click", function () {
    var b = this, texto = linhas().join(" && ");
    function ok() { b.textContent = "copiado"; setTimeout(function () { b.textContent = "copiar"; }, 1600); }
    function manual() { var r = document.createRange(); r.selectNodeContents(document.getElementById("comandos")); var s = getSelection(); s.removeAllRanges(); s.addRange(r); b.textContent = "Ctrl+C para copiar"; }
    if (navigator.clipboard) navigator.clipboard.writeText(texto).then(ok, manual); else manual();
  });

  // ---- a hora de quem visita, na barra de tarefas ----
  function hora() { var d = new Date(); document.getElementById("relogio").textContent = String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"); }
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
