defmodule TracyWeb.UserSessionHTML do
  use TracyWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:tracy, Tracy.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
