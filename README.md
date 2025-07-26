# 🔐 PIM-Global

[![Latest Release](https://img.shields.io/github/v/release/markorr321/PIM-Global?label=Download%20PIM-Global.exe&style=for-the-badge)](https://github.com/markorr321/PIM-Global/releases/latest)

> **Now available as a standalone `.exe`** in [v3.0.0.0](https://github.com/markorr321/PIM-Global/releases/tag/v3.0.0) – no PowerShell required.

PIM-Global is a lightweight, secure desktop utility designed to streamline Entra ID Privileged Identity Management (PIM) role activation across global tenants.

---

> 🚀 **New Version Released!**  
> `PIM-Global-v2.ps1` now supports **full role lifecycle management**, multi-role activation/deactivation, active role detection, and more.  
> The original `PIM-Global.ps1` remains available for compatibility.  
> [View the changelog →](./CHANGELOG.md)


## 🚀 Key Features

- ✅ Native executable — no script editing or PowerShell needed  
- 🌍 Multi-tenant support  
- 🔐 MSAL & Microsoft.Graph-based authentication  
- 🎨 Colorized CLI prompts & MFA guidance  
- 🖥️ Desktop-friendly (Electron-compatible variant included)  

---


🔐 Permissions Requested
When you run the script for the first time, Microsoft will prompt you to sign in and approve access to a few Microsoft Graph permissions:

| Permission                           | Why It's Needed                             |
| ------------------------------------ | ------------------------------------------- |
| `User.Read`                          | To identify you and sign in securely        |
| `RoleManagement.Read.Directory`      | To view which PIM roles you're eligible for |
| `RoleManagement.ReadWrite.Directory` | To activate eligible roles on your behalf   |


📌 These permissions are delegated meaning they only apply while you're signed in interactively using MFA.

👉 If you're the first person in your tenant to use the tool, Microsoft Entra may ask your admin to approve the requested permissions.
This is a one-time step built into the Microsoft sign-in experience no separate setup or consent URL is needed.


Essential PowerShell Prerequisites

# Ensure TLS 1.2 for secure downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Install modules

Install-Module MSAL.PS -Scope CurrentUser -Force

Install-Module Microsoft.Graph -Scope CurrentUser -Force

# Import modules

Import-Module MSAL.PS

Import-Module Microsoft.Graph

---

🧑‍💻 \[User] Run the Script

**Option A** — Run once via GitHub:

📅 Copy & paste this into PowerShell:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/markorr321/PIM-Global/main/PIM-Global-v2.ps1) }"
```

**Option B** — Clone the repo and run:

```powershell
git clone https://github.com/markorr321/PIM-Global.git
cd PIM-Global
.\PIM-Global-v2.ps1
```

---

## ✅ Requirements

* PowerShell 7+
* Graph modules auto-installed:

  * `Microsoft.Graph`
  * `MSAL.PS`
* User must be **eligible** for at least one PIM role

---

## 🧠 Example

### 🟢 Run the Script

![Run the Script](images/PIM%20-%20Manual%20Script%20Interaction.png)

### 👤 Select Your Account

![Account Selection](images/PIM%20-%20Account%20Selection.png)

### 🔑 Passkey Interaction

![Passkey Interaction](images/PIM%20-%20Device%20Selection.png)

### 📷 Scan QR Code

![QR Code Verification](images/PIM%20-%20QR%20Code%20Verification.png)

### ✅ MFA Confirmation

![MFA Confirmation](images/PIM%20-%20Final%20MFA.png)

### 🎭 Role Retrieval

![Role Selection](images/PIM%20-%20Role%20Selection.png)

### 🧾 Selecting Your Role

![Enter Role Number](images/PIM%20-%20Enter%20Role%20Number.png)

### ⏳ Role Duration

![Enter Activation Duration](images/PIM%20-%20Enter%20Activation%20Duration.png)

### 📝 Enter Reason for Activation

![Enter Reason](images/PIM%20-%20Enter%20reason%20for%20activation.png)

### 🟖️ Role Activation Complete

![Final Activation](images/PIM-Final.png)

---

## 🔐 Security

This tool uses:

* MSAL interactive login with ACRS enforcement (`acrs=c1`)
* No passwords or secrets stored
* Consent must be granted by a tenant admin

---

## 📜 License

[MIT License](LICENSE)

---

✉️ Questions?

Open an issue or contact **[morr@orr365.tech](mailto:morr@orr365.tech)**
or DM me on Twitter: [@MarkHunterOrr](https://twitter.com/MarkHunterOrr)
