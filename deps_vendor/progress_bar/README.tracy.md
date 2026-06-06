# Vendored progress_bar

Why it's here: upstream `progress_bar` 3.0.0 constrains `decimal ~> 2.0`,
which collides with `ecto 3.14`'s `decimal ~> 3.0`. The upstream package
is unmaintained — Henrik hasn't shipped a fix.

This is a verbatim copy of the upstream source with one character
changed in `mix.exs`:

    {:decimal, "~> 2.0"}   →   {:decimal, "~> 2.0 or ~> 3.0"}

`mix.exs` in tracy itself overrides the transitive resolution via
`{:progress_bar, path: "deps_vendor/progress_bar", override: true}`.

When upstream relaxes the constraint (or releases a 4.x that does),
delete this directory and remove the `:progress_bar` override line.

Upstream: https://github.com/henrik/progress_bar (MIT).
