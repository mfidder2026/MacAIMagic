---
title: Tasks and heartbeat
icon: clock.badge.checkmark
keywords: tasks task schedule scheduled background heartbeat checklist menu bar login notification notifications steps step list at once queue every day weekday
---
The model can also work while you are not watching: run a **task** at a set time, or go through a **checklist** now and then. Conversations can also go on at the same time.

## Making a task
Choose **Tasks** in the sidebar, then **New task…**.
- **Name** and the **instruction for the model**: write it as a complete question, for example "Give an overview of my appointments for today and the open reminders."
- **When**:

| Choice | Example |
|---|---|
| Once | tomorrow at 9:00 |
| Daily | every day, or weekdays only, at 8:00 |
| Weekly | every Friday at 17:00 |
| Every few hours | every 2 hours from 8:00 to 22:00 |

- **Work folder** (optional): the task can then read and write files there.

You can also just ask in a conversation: *"Give me my agenda every weekday at 8."* The model then plans the task, and the card first shows what and when.

> Tip: **Run now** tries a task at once, without waiting for its time.

## What happens when a task runs
- Each run becomes a conversation of its own ("⏱ name · date"). You find it in the sidebar and under Tasks in **Recent runs**.
- If the model is not loaded, the task loads it. When the tasks are done and you did not use the model, it stops again (Settings → Tasks).
- When the task is done you get a **notification** with the first line of the answer. A click opens the conversation.
- Reading is allowed. If the task wants to **change** something, you get a notification and the task waits until you approve or decline in the app. After a day without an answer it counts as no.
- If the Mac slept or the app was closed, a missed task runs once as soon as it can, if it is at most 12 hours late. An older one is skipped.

## Heartbeat
Settings → **Tasks** → **Heartbeat**. The model then goes through a checklist now and then, within the hours you choose, and only speaks up when there is something.
- **Open checklist** opens `HEARTBEAT.md`. Put your points below, one per line, for example "Is there an appointment in my calendar in the coming hour?"
- With nothing to report no conversation is left behind, only "Last check 10:00: nothing to report".
- If the model is not loaded, the heartbeat skips, unless **The model may load for this** is on. With a large model that costs minutes and power each time.
- The heartbeat waits while you are chatting or a task runs.

## With the window closed
When tasks or a heartbeat are on, MacAIMagic does not quit when you close the window. It stays at the top right in the **menu bar**: there you see whether the model is loaded, what runs and what the next task is. The model stops when the window closes, so the memory is free.
- **Start at login** (Settings → Tasks) starts MacAIMagic when you log in, so tasks also run after a restart.
- A task can only run while the Mac is on and awake. During a task the Mac does not go to sleep.

## Conversations at the same time
While the model works in one conversation, you can go on in another. The model writes one answer at a time: your question waits a moment ("Waiting for the model…") and then gets its turn. A conversation that waits for your approval does not hold up the others.
- In the sidebar a spinner shows a conversation at work, and an orange dot means: waiting for your approval.
- You can stop each conversation on its own, also with a right-click in the sidebar.

## Steps
For a larger job the model first lists the steps. You see them above the input field, ticked off as it works.
