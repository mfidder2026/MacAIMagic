---
title: Connectors
icon: puzzlepiece.extension
keywords: connectors MCP tools calendar reminders GitHub files fetch web import Claude Desktop log in OAuth token
---
A **connector** gives the model tools from another program or service, through the Model Context Protocol (MCP). For example your calendar, GitHub, or files outside the work folder.

## Adding a connector
Open Settings → **Connectors**.
- **Add an example** offers connectors that work right away:

| Example | What it does | Needs |
|---|---|---|
| Calendar and Reminders | show, create and complete events and reminders | nothing: built into the app |
| Files | read, search and write in Documents, Downloads and Desktop | `npx` (brew install node) |
| Fetch web | fetch a web page as text | `uvx` (brew install uv) |
| GitHub | repositories, issues and pull requests | a personal token from GitHub |

- **Add…** for your own connector: a *program on this Mac* (command and arguments, as in Claude Desktop) or an *internet address*.
- **Import** takes connectors over from Claude Desktop and Claude Code. They come in switched off, so you can look first.
- **Test connection** starts the connector briefly and shows which tools it has.

## How the model uses them
The model only sees the names of the connectors that are on. Only when it needs one does it load its tools ("Loading connector: GitHub"). They then stay in that conversation. That keeps the prompt short and the model fast. A connector with **Always loaded** is there in every conversation.

## Rights
Per connector you choose **Allow**, **Ask first** or **Deny**.
- A tool that says it only reads is allowed by default (except with Deny).
- Other tools ask first. The card shows the connector, the tool and exactly what is passed along.
- A red warning is added when a tool can delete something, when the connector is on the internet, or when the call follows reading the web.

## Logging in to a service
When a connector on the internet asks you to log in, the app opens the login page in your own browser. Then it carries on by itself. The token goes to the Keychain; MacAIMagic never sees your password. **Log out** is in the connector's menu. For a service without a login page (such as GitHub) you enter a token; that goes to the Keychain too.

## Calendar and Reminders
The first time, macOS asks whether MacAIMagic may use your calendar and reminders. You can change that later under System Settings → Privacy & Security.

> A connector on the internet sends what the model passes along to that service. With Ask first, look at the card carefully.

## Something does not work
Open **Log** in the connector's menu: it shows what the program or service reported. When `npx` or `uvx` is missing, the app says how to install it.
