# ThinkPad-P50
Lenovo  ThinkPad P50 Workstation setup and maintenance
  
  
<details>
  <summary>Post-install script Debian 13</summary>
  <p>Run on a clean Debian installation:</p>
  <pre><code>tmp="$(mktemp)" && wget -qO "$tmp" "https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/post-install-deb.sh" && bash "$tmp"; rc=$?; rm -f "$tmp"; (exit "$rc")</code></pre>
</details>
  
<details>
  <summary>Storage helper script Debian 13</summary>
  <p>Prepare storage on ThinkPad P50:</p>
  <pre><code>tmp="$(mktemp)" && wget -qO "$tmp" "https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/sotrage-helper.sh" && bash "$tmp"; rc=$?; rm -f "$tmp"; (exit "$rc")</code></pre>
</details>
  
<details>
  <summary>Fingerprint setup Debian 13</summary>
  <p>Initializing and enabling the Validity/Synaptics VFS7500 fingerprint reader:</p>
  <pre><code>tmp="$(mktemp)" &amp;&amp; curl -fsSL https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/fingerprint-deb.sh -o "$tmp" &amp;&amp; sudo bash "$tmp"; rm -f "$tmp"</code></pre>
</details>
  
<details>
  <summary>Install Nvidia Driver, Debian 13</summary>
  <p>Nvidia Driver installation, works on Secure boot:</p>
  <pre><code>tmp="$(mktemp)" &amp;&amp; curl -fsSL https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/refs/heads/main/nvidia-driver-install.sh -o "$tmp" &amp;&amp; bash "$tmp"; rm -f "$tmp"</code></pre>
</details>
