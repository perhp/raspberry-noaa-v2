![Raspberry NOAA](../assets/header_1600_v2.png)

In `config/settings.yml`, setting `enable_telegram_push: true` and configuring a `telegram_bot_token` and `telegram_chat_id` will
enable pushing all captured, processed images to a Telegram chat, group, or channel.

## Create a Telegram Bot

Open a chat with [@BotFather](https://t.me/BotFather) in Telegram and send `/newbot`. Follow the prompts to give your bot a name
and username. BotFather will respond with an HTTP API token that looks like `123456789:AAF-abc...` - this is your `telegram_bot_token`.

## Find your Chat ID

- For a private chat: send a message to your new bot, then visit `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates` in a browser
  and read the `chat.id` value from the response (alternatively, message [@userinfobot](https://t.me/userinfobot) to get your own id).
- For a group: add the bot to the group, send a message in the group, and use the same `getUpdates` URL - group chat ids are negative
  numbers (e.g. `-1001234567890`).
- For a channel: add the bot as an administrator of the channel; you can then use the channel's `@channelusername` directly as the
  chat id.

## Configure Settings and Update

Update your `config/settings.yml` to set `enable_telegram_push: true`, and set `telegram_bot_token` and `telegram_chat_id` to the
values obtained above. Then, re-run the installer script `./install_and_upgrade.sh`, which will align your environment.

## Testing (Optional)

If you'd like to see whether the configurations you've set are working, you can run a quick test from the command line using
an existing image (or any image for that matter). Simply run the following below, replacing `<PATH_TO_IMAGE>` with the fully-qualified
path to an image on the local file system:

```bash
./scripts/push_processors/push_telegram.sh "Test message" <PATH_TO_IMAGE>
```

If all goes well, you should see the image with your test message as its caption show up in your Telegram chat!

## Profit

Once the above have been performed, simply wait until your next capture occurs and you should then see the pass images pop up in
your Telegram chat with a caption indicating the satellite, pass, etc.
