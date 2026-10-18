# Warnings `mix dialyzer` reports that are not defects. Each one is named by file, kind and line,
# so a new warning of the same kind in the same file is still reported.
[
  # MapSet, :sets and Phoenix.LiveView.JS are opaque types: dialyzer reports a call that reads one
  # through its struct, which is what the standard library and LiveView do themselves.
  {"lib/mishka_cms_core/accounts/__calculations/by_master.ex", :call_without_opaque, 40},
  {"lib/mishka_cms_core/accounts/__validations/grant_within_actor_scope.ex", :call_without_opaque, 89},
  {"lib/mishka_cms_core/accounts/_helper.ex", :call_without_opaque, 130},
  {"lib/mishka_cms_core/activity/_helpers.ex", :call_without_opaque, 298},
  {"lib/mishka_cms_core/runtime/compilers/compiled_module_cache.ex", :call_without_opaque, 474},
  {"lib/mishka_cms_core/runtime/compilers/compiled_module_cache.ex", :call_with_opaque, 476},
  {"lib/mishka_cms_core/runtime/compilers/compiled_module_cache.ex", :call_with_opaque, 483},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session.ex", :call_with_opaque, 2056},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session.ex", :call_with_opaque, 2059},
  {"lib/mishka_cms_core/runtime/page_builder/fields.ex", :call_without_opaque, 219},
  {"lib/mishka_cms_core/runtime/page_builder/fields.ex", :call_with_opaque, 653},
  {"lib/mishka_cms_core/runtime/page_builder/history.ex", :call_without_opaque, 417},
  {"lib/mishka_cms_core/runtime/page_builder/marketplace/kits.ex", :call_without_opaque, 61},
  {"lib/mishka_cms_core/runtime/page_builder/strict.ex", :call_without_opaque, 190},
  {"lib/mishka_cms_core_web/live/admin/builder/panels.ex", :call_without_opaque, 4104},
  {"lib/mishka_cms_core_web/live/admin/builder/panels.ex", :call_without_opaque, 4149},
  {"lib/mishka_cms_core_web/live/admin/dashboard/runtime/preview_helpers.ex", :call_without_opaque, 1355},
  {"lib/mishka_cms_core_web/templates/_card_chrome.ex", :contract_with_opaque, 478},
  {"lib/mishka_cms_core_web/templates/_card_chrome.ex", :contract_with_opaque, 504},
  {"lib/mishka_cms_core_web/templates/_card_chrome.ex", :contract_with_opaque, 515},

  # `Strict.violation!/2` and `Strict.check!/3` are macros that compile to an unconditional `raise` in
  # :dev and :test (and to nothing in :prod), and dialyzer runs in :dev. Every function that reaches
  # one is "without a local return", and what depends on it is "never called" or "never matches".
  # The shipped (:prod) shape has none of these.
  {"lib/mishka_cms_core/builder/events.ex", :no_return, 318},
  {"lib/mishka_cms_core/runtime/page_builder/blocks.ex", :invalid_contract, 473},
  {"lib/mishka_cms_core/runtime/page_builder/blocks.ex", :no_return, 474},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session.ex", :no_return, 1378},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session.ex", :no_return, 1421},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session.ex", :no_return, 1449},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session.ex", :pattern_match, 1706},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session.ex", :pattern_match, 1714},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session.ex", :unused_fun, 1737},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session.ex", :unused_fun, 1739},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session.ex", :unused_fun, 1741},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session.ex", :pattern_match, 2666},
  {"lib/mishka_cms_core/runtime/page_builder/strict.ex", :pattern_match, 65},
  {"lib/mishka_cms_core/runtime/page_builder/strict.ex", :pattern_match, 82},
  {"lib/mishka_cms_core/runtime/page_builder/strict.ex", :pattern_match, 126},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match, 1014},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match, 5822},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match, 7198},

  # A last clause that matches anything, after clauses the current callers already cover. Kept on
  # purpose: it is the answer to a shape a plugin, a stored row or a later caller may send.
  {"lib/mishka_cms_core/runtime/compilers/component_compiler.ex", :pattern_match_cov, 1786},
  {"lib/mishka_cms_core/runtime/compilers/tailwind_compiler.ex", :pattern_match_cov, 1763},
  {"lib/mishka_cms_core/runtime/handlers/ui_kit_handler.ex", :pattern_match_cov, 758},
  {"lib/mishka_cms_core/runtime/page_builder/code_check.ex", :pattern_match_cov, 281},
  {"lib/mishka_cms_core/runtime/page_builder/editor_session/journal.ex", :pattern_match_cov, 415},
  {"lib/mishka_cms_core/runtime/page_builder/tree/styles.ex", :pattern_match_cov, 1250},
  {"lib/mishka_cms_core/runtime/resources/__changes/process_file_upload.ex", :pattern_match_cov, 152},
  {"lib/mishka_cms_core/runtime/runtime_preview.ex", :pattern_match_cov, 368},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match_cov, 5732},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match_cov, 6003},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match_cov, 6148},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match_cov, 6224},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match_cov, 6256},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match_cov, 6287},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match_cov, 6299},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match_cov, 6311},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match_cov, 6323},
  {"lib/mishka_cms_core_web/live/admin/builder/builder_live.ex", :pattern_match_cov, 7031},

  # `:elixir_tokenizer.tokenize/3` and the project's HEEx tokenizer are called through a clause for
  # each shape either has returned across Elixir releases; dialyzer sees the one of this release.
  {"lib/mishka_cms_core/runtime/page_builder/highlight.ex", :pattern_match, 76},
  {"lib/mishka_cms_core/runtime/page_builder/highlight.ex", :guard_fail, 93},

  # `Redirects.redirect/2` is typed from the `Plug.Conn` struct's defaults, which dialyzer then takes
  # for a conn nothing can answer; the plug is exercised by test/mishka_cms_core/runtime/plugs.
  {"lib/mishka_cms_core/runtime/plugs/site_lookup_plug.ex", :call, 430},
  {"lib/mishka_cms_core/runtime/plugs/site_lookup_plug.ex", :unused_fun, 437},
  {"lib/mishka_cms_core/runtime/plugs/site_lookup_plug.ex", :unused_fun, 569},
  {"lib/mishka_cms_core/runtime/plugs/site_lookup_plug.ex", :unused_fun, 583},
  {"lib/mishka_cms_core/runtime/plugs/site_lookup_plug.ex", :unused_fun, 594},
  {"lib/mishka_cms_core/runtime/plugs/site_lookup_plug.ex", :unused_fun, 600},
  {"lib/mishka_cms_core/runtime/plugs/site_lookup_plug.ex", :unused_fun, 608},

  # A guard or a comparison dialyzer proves false from a type, where the value is checked on
  # purpose (a limit that is always a number, a list that is a compile-time constant, a refusal map
  # whose keys the caller holds).
  {"lib/mishka_cms_core/activity/activity_entry.ex", :guard_fail, 419},
  {"lib/mishka_cms_core/runtime/page_builder/icons/heroicons.ex", :exact_compare, 111},
  {"lib/mishka_cms_core/runtime/page_builder/page_forms/_form_placement.ex", :guard_fail, 1578},
  {"lib/mishka_cms_core_web/live/admin/components/translations_refusal.ex", :call, 178},
  {"lib/mishka_cms_core_web/live/admin/components/translations_refusal.ex", :call, 210},
  {"lib/mishka_cms_core_web/live/admin/dashboard/runtime/preview_helpers.ex", :guard_fail, 1288}

]
