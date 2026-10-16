defmodule MishkaCmsCore.Runtime.PageBuilder.Tree.Styles do
  @moduledoc """
  Turns the inspector's recorded overrides into Tailwind utilities, and reads them back out again.

  ## Why classes and not a stylesheet

  ADR-8. The runtime Tailwind compiler only ever sees classes that appear in **server-rendered
  HTML**, so a rule invented at runtime and injected as CSS would never be generated. Writing the
  override as `max-[900px]:py-[14px]` on the element puts it exactly where the compiler looks. It
  also keeps the house rule intact — no `<style>` blocks, no static inline styles — and means an
  override is legible to anyone reading the template afterwards.

  ## Round trip

  `to_classes/1` appends generated utilities **after** whatever the author wrote, in a stable order.
  `from_classes/1` recognises the same shapes on the way back in and lifts them into `meta.styles`,
  leaving the author's own classes untouched. Parsing a template the editor saved therefore returns
  the same override map the inspector recorded — which is what makes the responsive panel show real
  state rather than a guess.

  A hand-written `hover:bg-[#111]` is absorbed too. That is deliberate: it means an override someone
  typed by hand becomes editable in the panel instead of being invisible to it, and it re-serializes
  byte-identically.

  A class is read only when writing its override back gives that same class, and only when it is the
  one class in its bucket that override would replace. Two of them — `text-[#fff] text-[#000]`, or
  `p-[20px]` beside an authored `px-8` — stay as the author wrote them: one value in the panel could
  only give one of them back.

  ## Buckets

  `:base` has no prefix. `:tablet` and `:mobile` are max-width queries at the prototype's
  breakpoints (900 and 560). `:hover`, `:focus` and `:active` are the state variants.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  @typedoc """
  One element of a `class={[…]}` expression: the classes a literal string holds, or the source of
  something the author works out at render time.
  """
  @type part :: {:classes, [String.t()]} | {:logic, String.t()}

  # A BUCKET IS A WIDTH AND A STATE, NOT ONE OR THE OTHER. It used to be either — the panel wrote to
  # the breakpoint while Normal was selected and to the state otherwise — so `:hover` meant "hovered,
  # at every width". Setting a hover colour while the panel said Mobile changed the desktop too, and
  # there was no way to say "on a phone, when touched".
  #
  # Tailwind already composes them: `max-[560px]:hover:` is exactly "narrow AND hovered". So the two
  # axes are a matrix, and the six pairs below are the ones that were missing.
  #
  # A state with no width still means every width, which is what makes the common case cheap: set a
  # hover on Desktop and it holds on a phone too, unless the phone says otherwise.
  @variants %{
    base: nil,
    tablet: "max-[900px]",
    mobile: "max-[560px]",
    hover: "hover",
    focus: "focus",
    active: "active",
    tablet_hover: "max-[900px]:hover",
    tablet_focus: "max-[900px]:focus",
    tablet_active: "max-[900px]:active",
    mobile_hover: "max-[560px]:hover",
    mobile_focus: "max-[560px]:focus",
    mobile_active: "max-[560px]:active"
  }

  # EMISSION ORDER IS THE CASCADE. `hover:bg-x` and `max-[560px]:hover:bg-y` are both one class and
  # one pseudo-class — the same specificity — so on a phone the one written LAST wins. The pairs come
  # after the plain states for that reason, and the narrower pair after the wider one.
  @bucket_order [
    :base,
    :tablet,
    :mobile,
    :hover,
    :focus,
    :active,
    :tablet_hover,
    :tablet_focus,
    :tablet_active,
    :mobile_hover,
    :mobile_focus,
    :mobile_active
  ]

  @doc """
  The bucket a width and a state name together.

  `{:mobile, :hover}` is `:mobile_hover`; a state at the widest breakpoint keeps its own name,
  because `hover:` with no query already applies at every width.
  """
  @spec bucket(atom(), atom()) :: atom()
  def bucket(:base, :base), do: :base
  def bucket(breakpoint, :base), do: breakpoint
  def bucket(:base, pseudo), do: pseudo
  def bucket(breakpoint, pseudo), do: :"#{breakpoint}_#{pseudo}"

  @doc "The width and the state a bucket stands for — the inverse of `bucket/2`."
  @spec axes(atom()) :: {atom(), atom()}
  def axes(bucket) do
    case Atom.to_string(bucket) |> String.split("_", parts: 2) do
      [breakpoint, pseudo] ->
        {String.to_existing_atom(breakpoint), String.to_existing_atom(pseudo)}

      [only] ->
        lone_axis(String.to_existing_atom(only))
    end
  end

  @pseudos [:hover, :focus, :active]

  defp lone_axis(bucket) when bucket in @pseudos, do: {:base, bucket}
  defp lone_axis(bucket), do: {bucket, :base}

  # The property names the inspector writes, mapped to the Tailwind utility that expresses them.
  # Anything not listed here is skipped rather than guessed at — a wrong utility is worse than none.
  #
  # The mapping MUST stay injective, because `from_classes/1` inverts it. Tailwind spells both text
  # colour and text size `text-…`, distinguishing them only by the value's type (`@prefix_kinds`) —
  # so `color` owns `text-` and font size is written as its own property rather than as a second
  # claim on the prefix. `styles_test.exs` fails the build if a second property ever claims a utility.
  @utilities %{
    "gap" => "gap",
    "padding" => "p",
    "py" => "py",
    "px" => "px",
    "pt" => "pt",
    "pb" => "pb",
    "pl" => "pl",
    "pr" => "pr",
    "margin" => "m",
    "my" => "my",
    "mx" => "mx",
    "mt" => "mt",
    "mb" => "mb",
    "ml" => "ml",
    "mr" => "mr",
    "width" => "w",
    "height" => "h",
    "min-height" => "min-h",
    "max-width" => "max-w",
    "radius" => "rounded",
    "background" => "bg",
    "color" => "text",
    "border-color" => "border",
    "opacity" => "opacity",
    "z-index" => "z",
    "line-height" => "leading",
    "letter-spacing" => "tracking",
    "shadow" => "shadow",
    "grid-cols" => "grid-cols"
  }

  @by_utility Map.new(@utilities, fn {prop, util} -> {util, prop} end)

  # WHEN THE NAMESPACE IS ALREADY SPOKEN FOR. `text-` is text colour here and `border-` is border
  # colour, and the map above has to stay injective — so font size and border width cannot be given a
  # utility without making the inverse guess at which of two properties a class meant.
  #
  # Tailwind's arbitrary-PROPERTY syntax writes the CSS property itself, `[font-size:3rem]`, and is
  # unambiguous by construction: the property is in the class. It carries variants the same way
  # (`max-[900px]:[font-size:2rem]`), so nothing else in this module has to know the difference.
  @raw_properties ~w(font-size border-width)

  # AND ONE PROPERTY THAT IS BOTH. `background` is a colour nine times out of ten, and `bg-[#fff]` is
  # how Tailwind spells that — but it is also the SHORTHAND, and a picture needs the whole of it:
  # `url(…) center/cover no-repeat`. Tailwind's `bg-` takes one type at a time, so handed a shorthand
  # it generates a rule that sets nothing at all: the class is in the sheet, the element has it, and
  # `background-image` reads `none`. A control that looks applied and paints nothing.
  #
  # So the VALUE decides the spelling, the same way a column count does: a colour keeps `bg-[…]`, and
  # anything with a space in it is written as the property itself. Both parse back to `background`.
  @raw_parse @raw_properties ++ ["background"]

  # A BARE NUMBER IN A LENGTH FIELD MEANS PIXELS. Tailwind's arbitrary-value syntax takes a real CSS
  # value, so `p-[8]` compiles to nothing at all — the class lands on the element, the panel shows
  # `8`, and the padding stays zero. Typing a number into a box labelled Padding plainly means eight
  # pixels, so that is what it writes.
  #
  # Only for the properties that ARE lengths: a bare number is exactly right for opacity and
  # z-index, and a colour is never a number.
  @lengths ~w(gap padding py px pt pb pl pr margin my mx mt mb ml mr width height min-height
              max-width radius font-size letter-spacing border-width)

  @doc """
  The properties whose value is a CSS LENGTH, and which therefore read a bare number as pixels.

  Public because the panel labels them: a box that takes `50%` and `2rem` and says only "unset" is a
  box people conclude is pixels-only, which is what happened.
  """
  @spec lengths() :: [String.t()]
  def lengths, do: @lengths

  # Properties whose values ARE the utility rather than an arbitrary value in brackets: Tailwind
  # spells display as `flex`, not `display-[flex]`. They round-trip the same way — a bare `flex` in a
  # class attribute is read back as a display override and re-emitted verbatim — which is what lets
  # the panel show a real Display value for a template nobody edited visually.
  #
  # Values must stay unique across properties for the same reason the utility map must stay
  # injective; `styles_test.exs` fails the build if that is ever broken.
  @enums %{
    "display" => ~w(flex block grid),
    "direction" => ~w(flex-row flex-col flex-row-reverse flex-col-reverse),
    "justify" =>
      ~w(justify-start justify-center justify-end justify-between justify-around justify-evenly),
    "align" => ~w(items-start items-center items-end items-stretch items-baseline),
    "wrap" => ~w(flex-wrap flex-nowrap),
    "font-weight" =>
      ~w(font-light font-normal font-medium font-semibold font-bold font-extrabold),
    "text-align" => ~w(text-left text-center text-right text-justify),
    "text-transform" => ~w(uppercase lowercase capitalize normal-case),
    "border-style" => ~w(border-solid border-dashed border-dotted border-none)
  }

  @by_enum_value for {prop, values} <- @enums, value <- values, into: %{}, do: {value, prop}

  @doc "The style buckets, in the order their classes are emitted."
  @spec buckets() :: [atom()]
  def buckets, do: @bucket_order

  # PROPERTIES THAT ONLY MEAN SOMETHING ON A FLEX CONTAINER. `flex-col-reverse` and `items-center` do
  # nothing to a `block` element, so leaving them behind when the author switches back writes dead
  # classes into the page and leaves the Inspector showing settings that have no effect — and they
  # spring back to life, unasked, if the element is ever made a row again.
  @flex_only ~w(direction justify align wrap)

  # AND THE ONE THAT ONLY MEANS SOMETHING ON A GRID. A column track list left behind on an element
  # that is no longer a grid is the same dead weight, and springs back the same way.
  @grid_only ~w(grid-cols)

  @doc """
  The overrides that stop meaning anything once `prop` is set to `value`, and should go with it.

  Lives here rather than in a panel because the vocabulary is what knows which properties depend on
  which — so the toolbar, the Inspector and anything added later all drop the same set, in the same
  single undoable step.
  """
  @spec dependents(String.t(), String.t() | nil) :: [String.t()]
  def dependents("display", value) do
    Enum.concat(
      (value != "flex" && @flex_only) || [],
      (value != "grid" && @grid_only) || []
    )
  end

  def dependents(_prop, _value), do: []

  @doc "The CSS-ish property names the panel can express as a utility."
  @spec properties() :: [String.t()]
  def properties, do: Map.keys(@utilities) ++ Map.keys(@enums) ++ @raw_properties

  # EVERY OPTION DEMONSTRATES ITSELF. `justify-around` is not a phrase anyone outside this trade
  # knows, so each value carries a plain-words name and a picture: a little box laid out with THE
  # SAME RULE the value applies, so `space-between` really is space-between in the swatch. A reader
  # who has never met the word picks the one that looks like what they want.
  #
  # The picture is described twice because it is drawn in two documents. The element toolbar lives
  # inside the canvas iframe, which is served the AUTHOR's compiled stylesheet — the admin's Tailwind
  # classes do not exist there, so it needs raw CSS. The Inspector is in the admin document, where
  # the house rule is Tailwind and only Tailwind. One list, two spellings, rather than two lists that
  # drift.
  #
  # `bars` is how many children the swatch draws: enough to read the rule, no more. Alignment needs
  # three of unequal height to show a baseline; wrapping needs four to have something to wrap.
  @pictures %{
    "display" => [
      {"block", gettext_noop("Stacked"), "flex flex-col", "display:flex;flex-direction:column;",
       3},
      {"flex", gettext_noop("Row"), "flex", "display:flex;", 3},
      {"grid", gettext_noop("Grid"), "grid grid-cols-2",
       "display:grid;grid-template-columns:1fr 1fr;", 4}
    ],
    "direction" => [
      {"flex-row", gettext_noop("Left to right"), "flex flex-row",
       "display:flex;flex-direction:row;", 3},
      {"flex-col", gettext_noop("Top to bottom"), "flex flex-col",
       "display:flex;flex-direction:column;", 3},
      {"flex-row-reverse", gettext_noop("Right to left"), "flex flex-row-reverse",
       "display:flex;flex-direction:row-reverse;", 3},
      {"flex-col-reverse", gettext_noop("Bottom to top"), "flex flex-col-reverse",
       "display:flex;flex-direction:column-reverse;", 3}
    ],
    "justify" => [
      {"justify-start", gettext_noop("Pack to the start"), "flex justify-start",
       "display:flex;justify-content:flex-start;", 2},
      {"justify-center", gettext_noop("Pack to the centre"), "flex justify-center",
       "display:flex;justify-content:center;", 2},
      {"justify-end", gettext_noop("Pack to the end"), "flex justify-end",
       "display:flex;justify-content:flex-end;", 2},
      {"justify-between", gettext_noop("Space between"), "flex justify-between",
       "display:flex;justify-content:space-between;", 2},
      {"justify-around", gettext_noop("Space around"), "flex justify-around",
       "display:flex;justify-content:space-around;", 2},
      {"justify-evenly", gettext_noop("Space evenly"), "flex justify-evenly",
       "display:flex;justify-content:space-evenly;", 2}
    ],
    "align" => [
      {"items-start", gettext_noop("Align to the top"), "flex items-start",
       "display:flex;align-items:flex-start;", 3},
      {"items-center", gettext_noop("Align to the middle"), "flex items-center",
       "display:flex;align-items:center;", 3},
      {"items-end", gettext_noop("Align to the bottom"), "flex items-end",
       "display:flex;align-items:flex-end;", 3},
      {"items-stretch", gettext_noop("Stretch to fill"), "flex items-stretch",
       "display:flex;align-items:stretch;", 3},
      {"items-baseline", gettext_noop("Sit on one baseline"), "flex items-baseline",
       "display:flex;align-items:baseline;", 3}
    ],
    "wrap" => [
      {"flex-nowrap", gettext_noop("Keep on one line"), "flex flex-nowrap",
       "display:flex;flex-wrap:nowrap;", 4},
      {"flex-wrap", gettext_noop("Wrap to the next line"), "flex flex-wrap",
       "display:flex;flex-wrap:wrap;", 4}
    ]
  }

  # A value with no picture is a value the icon panels cannot show, which is how `items-baseline`
  # went missing from the toolbar for a while: the vocabulary grew and the pictures did not. The
  # build fails now instead.
  # A PICTURE MADE OF BARS CANNOT SHOW "BOLD". The swatch above draws a little box laid out by the
  # rule its value applies, which is exactly right for a layout property and says nothing at all
  # about a typeface or a border stroke — four grey bars are four grey bars however heavy the font.
  #
  # These demonstrate themselves the other way round: the OPTION'S OWN LABEL is drawn in the thing it
  # names. "Bold" is bold, "UPPERCASE" is upper case, "Dashed" is underlined with a dashed rule. Same
  # principle as the pictures, in the medium that can carry it.
  #
  # `{value, title, tailwind, css}` — `tailwind` styles the label in the Inspector, `css` does the
  # same job inside the canvas iframe, which has no admin classes.
  @labels %{
    "font-weight" => [
      {"font-light", gettext_noop("Light"), "font-light", "font-weight:300;"},
      {"font-normal", gettext_noop("Normal"), "font-normal", "font-weight:400;"},
      {"font-medium", gettext_noop("Medium"), "font-medium", "font-weight:500;"},
      {"font-semibold", gettext_noop("Semibold"), "font-semibold", "font-weight:600;"},
      {"font-bold", gettext_noop("Bold"), "font-bold", "font-weight:700;"},
      {"font-extrabold", gettext_noop("Black"), "font-extrabold", "font-weight:800;"}
    ],
    "text-align" => [
      {"text-left", gettext_noop("Left"), "text-left", "text-align:left;"},
      {"text-center", gettext_noop("Centre"), "text-center", "text-align:center;"},
      {"text-right", gettext_noop("Right"), "text-right", "text-align:right;"},
      {"text-justify", gettext_noop("Justify"), "text-justify", "text-align:justify;"}
    ],
    "text-transform" => [
      {"normal-case", gettext_noop("As typed"), "normal-case", "text-transform:none;"},
      {"uppercase", gettext_noop("UPPER"), "uppercase", "text-transform:uppercase;"},
      {"lowercase", gettext_noop("lower"), "lowercase", "text-transform:lowercase;"},
      {"capitalize", gettext_noop("Title"), "capitalize", "text-transform:capitalize;"}
    ],
    "border-style" => [
      {"border-solid", gettext_noop("Solid"), "underline decoration-solid decoration-2",
       "text-decoration:underline solid 2px;"},
      {"border-dashed", gettext_noop("Dashed"), "underline decoration-dashed decoration-2",
       "text-decoration:underline dashed 2px;"},
      {"border-dotted", gettext_noop("Dotted"), "underline decoration-dotted decoration-2",
       "text-decoration:underline dotted 2px;"},
      {"border-none", gettext_noop("None"), "line-through", "text-decoration:line-through;"}
    ]
  }

  # EVERY ENUMERATED VALUE MUST BE EXPLAINED, one way or the other. An option that reaches a panel
  # with neither a picture nor a styled label arrives as a bare Tailwind class for the reader to
  # decode, which is the thing this vocabulary exists to prevent. Checked at compile time, so a value
  # added to `@enums` and nowhere else fails the build rather than the reader.
  for {prop, values} <- @enums do
    described =
      case {Map.get(@pictures, prop), Map.get(@labels, prop)} do
        {nil, nil} -> raise "Styles: #{prop} has neither pictures nor labels"
        {nil, labels} -> Enum.map(labels, &elem(&1, 0))
        {pictures, nil} -> Enum.map(pictures, &elem(&1, 0))
        {_pictures, _labels} -> raise "Styles: #{prop} is described twice"
      end

    if Enum.sort(described) != Enum.sort(values) do
      raise "Styles: #{prop} is described as #{inspect(described)}, not #{inspect(values)}"
    end
  end

  @doc """
  Each value of an enumerated property with the words and the picture that explain it.

  `{value, title, tailwind, css, bars}` — `tailwind` for the admin panel, `css` for the toolbar
  inside the canvas iframe, which is served the author's stylesheet and has no admin classes.
  Returns `[]` for a free-form property.
  """
  @spec pictures(String.t()) :: [{String.t(), String.t(), String.t(), String.t(), pos_integer()}]
  def pictures(prop), do: @pictures |> Map.get(prop, []) |> Enum.map(&translated_title(&1, 1))

  @doc """
  Each value of a property whose options are explained by their own LABEL rather than by a picture.

  `{value, title, tailwind, css}`. Returns `[]` for anything pictured or free-form, so a panel can
  ask both and draw whichever answers.
  """
  @spec labels(String.t()) :: [{String.t(), String.t(), String.t(), String.t()}]
  def labels(prop), do: @labels |> Map.get(prop, []) |> Enum.map(&translated_title(&1, 1))

  defp translated_title(option, at),
    do: put_elem(option, at, Gettext.gettext(MishkaCmsCore.Gettext, elem(option, at)))

  @doc "The plain-words name of one enumerated value, or the value itself when nothing describes it."
  @spec value_title(String.t(), String.t()) :: String.t()
  def value_title(prop, value) do
    described = pictures(prop) ++ labels(prop)

    case Enum.find(described, &(elem(&1, 0) == value)) do
      nil -> value
      option -> elem(option, 1)
    end
  end

  # THE GAPS PEOPLE ACTUALLY PICK. Spacing is a free-form property — any length is legal — but
  # offering only a text box means typing `16px` to get the thing every design system already calls
  # "medium". The field stays for anything else.
  @gap_presets [
    {"0px", gettext_noop("None")},
    {"4px", gettext_noop("XS")},
    {"8px", gettext_noop("S")},
    {"12px", gettext_noop("M")},
    {"16px", gettext_noop("L")},
    {"24px", gettext_noop("XL")},
    {"32px", gettext_noop("2XL")}
  ]

  @doc "The one-click spacing values offered beside the gap field."
  @spec gap_presets() :: [{String.t(), String.t()}]
  def gap_presets, do: Enum.map(@gap_presets, &translated_title(&1, 1))

  @doc """
  The fixed set of values a property accepts, or `[]` when it takes a free-form value.

  This is what tells the inspector to render a select instead of a text field.
  """
  @spec options(String.t()) :: [String.t()]
  def options(prop), do: Map.get(@enums, prop, [])

  # THE INTERNAL NAME IS NOT A CSS PROPERTY. `py` and `radius` are this module's shorthand, chosen to
  # sit next to the Tailwind utility they compile to, and an enumerated value is a whole Tailwind
  # class rather than a value — so an override map printed as though it were CSS reads
  # `align: items-center`, which no browser has ever understood. Anything that shows an author their
  # overrides has to translate, and the vocabulary belongs beside the one it translates from.
  @css_properties %{
    "py" => "padding-block",
    "px" => "padding-inline",
    "pt" => "padding-top",
    "pb" => "padding-bottom",
    "pl" => "padding-left",
    "pr" => "padding-right",
    "my" => "margin-block",
    "mx" => "margin-inline",
    "mt" => "margin-top",
    "mb" => "margin-bottom",
    "ml" => "margin-left",
    "mr" => "margin-right",
    "radius" => "border-radius",
    "background" => "background-color",
    "display" => "display",
    "direction" => "flex-direction",
    "justify" => "justify-content",
    "align" => "align-items",
    "wrap" => "flex-wrap",
    "shadow" => "box-shadow",
    "grid-cols" => "grid-template-columns"
  }

  @css_values %{
    "flex-row" => "row",
    "flex-col" => "column",
    "flex-row-reverse" => "row-reverse",
    "flex-col-reverse" => "column-reverse",
    "justify-start" => "flex-start",
    "justify-center" => "center",
    "justify-end" => "flex-end",
    "justify-between" => "space-between",
    "justify-around" => "space-around",
    "justify-evenly" => "space-evenly",
    "items-start" => "flex-start",
    "items-center" => "center",
    "items-end" => "flex-end",
    "items-stretch" => "stretch",
    "items-baseline" => "baseline",
    "flex-wrap" => "wrap",
    "flex-nowrap" => "nowrap",
    "font-light" => "300",
    "font-normal" => "400",
    "font-medium" => "500",
    "font-semibold" => "600",
    "font-bold" => "700",
    "font-extrabold" => "800",
    "text-left" => "left",
    "text-center" => "center",
    "text-right" => "right",
    "text-justify" => "justify",
    "normal-case" => "none",
    "border-solid" => "solid",
    "border-dashed" => "dashed",
    "border-dotted" => "dotted",
    "border-none" => "none"
  }

  @doc """
  One recorded override as the CSS declaration it means, for anything that shows an author their own
  styling. `{"py", "16px"}` reads `padding-block: 16px`, and `{"align", "items-center"}` reads
  `align-items: center`.

  A property this module names the same way CSS does, and a free-form value, pass straight through.
  """
  @spec declaration(String.t(), String.t()) :: {String.t(), String.t()}
  def declaration(prop, value),
    do: {Map.get(@css_properties, prop, prop), Map.get(@css_values, value, value)}

  # THE VOCABULARY READ BACKWARDS, so hand-written CSS can be compared against the panel's overrides.
  # Built from `@utilities` and `@enums` through `@css_properties` rather than written out again: a
  # property added above joins this map on the same line it is declared, and cannot be forgotten.
  @all_properties Map.keys(@utilities) ++ Map.keys(@enums) ++ @raw_properties

  @controls_by_css Map.new(@all_properties, &{Map.get(@css_properties, &1, &1), &1})

  if map_size(@controls_by_css) != length(@all_properties) do
    raise "Styles: two controls claim one CSS property — the inverse would be ambiguous"
  end

  # A SHORTHAND OVERRIDES THE LONGHANDS IT CONTAINS. Writing `padding: 20px` by hand beats the panel's
  # Padding top as surely as it beats its Padding, so a collision check that compared property names
  # exactly would stay silent on the case authors hit first. Only the families the panel actually
  # splits are listed — inventing a general shorthand expander would flag things nobody can act on.
  @shorthand_covers %{
    "padding" => ~w(py px pt pb pl pr),
    "padding-block" => ~w(pt pb),
    "padding-inline" => ~w(pl pr),
    "margin" => ~w(my mx mt mb ml mr),
    "margin-block" => ~w(mt mb),
    "margin-inline" => ~w(ml mr),
    "background" => ~w(background)
  }

  # THE SAME CONTAINMENT, READ AS TAILWIND UTILITIES. `@shorthand_covers` is keyed by CSS property
  # because that is what a hand-written declaration carries; an authored CLASS carries a utility
  # prefix instead, and the two vocabularies have to agree or the panel disagrees with itself.
  #
  # Padding is where it showed: the panel's Padding writes `p-[40px]`, and a block that already reads
  # `px-6 py-16` kept both — `p` is not `px`, so neither authored class was dropped, and Tailwind
  # orders `px-*` after `p-*`, so the value the author had just typed lost on every edge. It was in
  # the class list and did nothing. Margin had it too, `m` against `mx`/`my`.
  #
  # Derived rather than written out, so a family added to `@shorthand_covers` is covered here on the
  # same line it is declared.
  @supersedes Map.new(Map.keys(@utilities), fn prop ->
                covered =
                  @shorthand_covers
                  |> Map.get(Map.get(@css_properties, prop, prop), [])
                  |> Enum.map(&Map.get(@utilities, &1))

                {prop,
                 [Map.get(@utilities, prop) | covered] |> Enum.reject(&is_nil/1) |> Enum.uniq()}
              end)

  # The same, read from the class: the controls an authored `px-8` gives way to.
  @superseded_by Enum.group_by(
                   for({prop, utils} <- @supersedes, util <- utils, do: {util, prop}),
                   &elem(&1, 0),
                   &elem(&1, 1)
                 )

  @doc """
  The style controls a hand-written CSS property overrides — `[]` when the panel has no say in it.

  `"padding-block"` answers `["py", "pt", "pb"]`: the control that owns the property outright, plus
  the longhands a shorthand swallows. Used by the inspector to mark a control whose value the
  element's own CSS has taken over, and by `from_declaration/2` in reverse.
  """
  @spec controls_for(String.t()) :: [String.t()]
  def controls_for(property) when is_binary(property) do
    property = property |> String.trim() |> String.downcase()

    (List.wrap(@controls_by_css[property]) ++ Map.get(@shorthand_covers, property, []))
    |> Enum.uniq()
  end

  def controls_for(_property), do: []

  @doc """
  One hand-written declaration as the override it would become, or `:error` when no control can hold
  it — which is what decides whether **Move to controls** is offered beside it.

  Exact only: `padding: 20px` becomes the Padding override and never the four longhands it also
  overrides, because moving it into `pt` alone would change what the page looks like.
  """
  @spec from_declaration(String.t(), String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def from_declaration(property, value) when is_binary(property) and is_binary(value) do
    case @controls_by_css[property |> String.trim() |> String.downcase()] do
      nil -> :error
      prop -> control_value(prop, String.trim(value))
    end
  end

  def from_declaration(_property, _value), do: :error

  # An enumerated control holds a Tailwind class, not a CSS value, so `align-items: center` has to
  # come back as `items-center`. The kit's own spelling is accepted too — `display: flex` is written
  # the same way in both vocabularies.
  defp control_value(prop, value) do
    case Map.get(@enums, prop) do
      nil -> free_form(prop, value)
      options -> enum_value(prop, options, value)
    end
  end

  defp enum_value(prop, options, value) do
    case Enum.find(options, &(&1 == value or Map.get(@css_values, &1, &1) == value)) do
      nil -> :error
      option -> {:ok, {prop, option}}
    end
  end

  # `!important` cannot survive the move: the panel writes a utility, which carries no such weight,
  # so a value that leans on it would quietly stop winning. Left in the text instead.
  defp free_form(_prop, ""), do: :error

  defp free_form(prop, value) do
    case String.contains?(String.downcase(value), "!important") do
      true -> :error
      false -> {:ok, {prop, value}}
    end
  end

  @doc """
  Compiles an override map into a list of Tailwind classes, in bucket order.

  Returns `[]` for an empty map, so a node with no overrides gains no classes and its `class`
  attribute is left exactly as the author wrote it.
  """
  @spec to_classes(map(), keyword()) :: [String.t()]
  def to_classes(styles, opts \\ [])

  def to_classes(styles, opts) when is_map(styles) do
    important? = Keyword.get(opts, :important?, false)

    for bucket <- @bucket_order,
        props = Map.get(styles, bucket),
        is_map(props),
        {prop, value} <- Enum.sort(props),
        class = class_for(bucket, prop, value),
        not is_nil(class),
        do: emphasise(class, important?)
  end

  def to_classes(_styles, _opts), do: []

  # WHEN THE CLASS TO BEAT IS NOT IN THIS ATTRIBUTE. `overridden?/2` wins the ordinary tie by DROPPING
  # the authored class an override claims — but a kit component renders `bg-white` from its own
  # variant, inside its own template, where nothing here can reach it. Two single-class selectors then
  # tie on specificity and the compiled bundle's order decides, which is how setting a background on a
  # component put the class on the element and changed nothing on screen.
  #
  # Tailwind v4 spells important as a SUFFIX — `bg-[#f00]!` — and it goes after the whole utility, so
  # a variant keeps its prefix: `md:bg-[#f00]!`.
  defp emphasise(class, false), do: class
  defp emphasise(class, true), do: class <> "!"

  defp class_for(bucket, prop, value) when prop in @raw_properties,
    do: raw_class(bucket, prop, value)

  defp class_for(bucket, "background", value) do
    case shorthand?(value) do
      true -> raw_class(bucket, "background", value)
      false -> arbitrary_class(bucket, "background", value)
    end
  end

  defp class_for(bucket, "grid-cols", value) do
    case count?(value) do
      true -> scale_class(bucket, "grid-cols", value)
      false -> arbitrary_class(bucket, "grid-cols", value)
    end
  end

  defp class_for(bucket, prop, value) do
    case Map.get(@enums, prop) do
      nil -> arbitrary_class(bucket, prop, value)
      values -> enum_class(bucket, values, value)
    end
  end

  # A COLUMN COUNT IS TAILWIND'S OWN UTILITY, NOT AN ARBITRARY VALUE. `grid-cols-[3]` compiles to
  # `grid-template-columns: 3`, which is not a track list and lays out nothing — the count has to
  # become `repeat(3, minmax(0, 1fr))`, and `grid-cols-3` is how Tailwind already spells that.
  #
  # Emitting the scale utility is also what lets the blocks be READ: they are written `grid-cols-3`,
  # so the panel opens on a real column count instead of on an empty control over a class it could
  # see and not name, and the class re-serializes byte-identically. The bracket is left for a track
  # list a count cannot express, like `2fr 1fr`.
  # A SPACE INSIDE BRACKETS IS NOT A SHORTHAND. Modern colour syntax is full of them — `rgb(0 0 0)`,
  # `hsl(210 40% 50%)`, `oklch(.7 .1 200)` — so the test is a space at the TOP level, once every
  # bracketed group is taken out. A gradient survives that and stays on `bg-[…]`, which is right:
  # Tailwind reads it as a background image. `url(` is named outright because a picture always wants
  # the shorthand, even written on its own.
  defp shorthand?(value) do
    value = to_string(value)

    String.contains?(String.downcase(value), "url(") or
      value |> without_groups() |> String.contains?(" ")
  end

  defp without_groups(value) do
    case String.replace(value, ~r/\([^()]*\)/, "") do
      ^value -> value
      stripped -> without_groups(stripped)
    end
  end

  @max_columns 12

  defp count?(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number in 1..@max_columns
      _not_a_count -> false
    end
  end

  defp scale_class(bucket, util, value) do
    case Map.get(@variants, bucket, :missing) do
      :missing -> nil
      variant -> prefix(variant) <> util <> "-" <> to_string(value)
    end
  end

  defp raw_class(bucket, prop, value) do
    case Map.get(@variants, bucket, :missing) do
      :missing -> nil
      variant -> prefix(variant) <> "[" <> prop <> ":" <> escape(with_unit(prop, value)) <> "]"
    end
  end

  defp enum_class(bucket, values, value) do
    with variant when variant != :missing <- Map.get(@variants, bucket, :missing),
         true <- to_string(value) in values do
      prefix(variant) <> to_string(value)
    else
      _unmappable -> nil
    end
  end

  defp arbitrary_class(bucket, prop, value) do
    with util when not is_nil(util) <- Map.get(@utilities, prop),
         variant <- Map.get(@variants, bucket, :missing),
         true <- variant != :missing do
      prefix(variant) <> util <> "-[" <> escape(with_unit(prop, value)) <> "]"
    else
      _unmappable -> nil
    end
  end

  defp with_unit(prop, value) when prop in @lengths do
    value = to_string(value)

    case Integer.parse(value) do
      {_number, ""} -> value <> "px"
      {_number, "." <> _decimals} -> maybe_px(value)
      _not_a_bare_number -> value
    end
  end

  defp with_unit(_prop, value), do: to_string(value)

  defp maybe_px(value) do
    case Float.parse(value) do
      {_number, ""} -> value <> "px"
      _has_a_unit -> value
    end
  end

  defp prefix(nil), do: ""
  defp prefix(variant), do: variant <> ":"

  # Tailwind's arbitrary-value syntax uses `_` for a space, and a literal space would end the class.
  defp escape(value), do: value |> to_string() |> String.replace(" ", "_")

  defp unescape(value), do: String.replace(value, "_", " ")

  # ONE PREFIX, TWO PROPERTIES. Tailwind spells a font size and a colour both `text-[…]` and tells
  # them apart by the value in the brackets: `text-[14px]` is a size, `text-[#9a96c4]` a colour. It
  # tries a fixed list of types in order, takes a `type:` hint over the guess
  # (`text-[length:var(--x)]`), and falls back to one property when nothing matches, so `var(--x)`
  # alone is a colour. Read as "every `text-[…]` is a colour", an element wearing both lost its size
  # on every parse — every save, and every compile of a page holding a hidden element.
  #
  # `{fallback, [{kind, types}]}`, the kinds in the order Tailwind tries their types. `number` under
  # `text` is ours: Tailwind reads `text-[14]` as a colour that paints nothing, and it is a size.
  @prefix_kinds %{
    "text" =>
      {:colour,
       [colour: ~w(color), size: ~w(length percentage absolute-size relative-size number size)]},
    "border" => {:colour, [colour: ~w(color), width: ~w(line-width length)]},
    "bg" =>
      {:colour,
       [
         image: ~w(image url),
         colour: ~w(color),
         position: ~w(percentage position),
         size: ~w(bg-size length size)
       ]},
    "shadow" => {:shadow, [colour: ~w(color)]}
  }

  # The control whose override replaces a class of each kind. A shadow's colour belongs to the Shadow
  # control: Tailwind paints an arbitrary shadow in it, so one left beside a new shadow recolours it.
  @kind_controls %{
    {"text", :colour} => "color",
    {"text", :size} => "font-size",
    {"border", :colour} => "border-color",
    {"border", :width} => "border-width",
    {"bg", :colour} => "background",
    {"bg", :image} => "background",
    {"shadow", :shadow} => "shadow",
    {"shadow", :colour} => "shadow"
  }

  # The kinds this module writes in each prefix, which are the only ones it reads back. A size is
  # written `[font-size:…]` and a width `[border-width:…]`, so `text-[14px]` stays the author's.
  @read_kinds %{
    "text" => [:colour],
    "border" => [:colour],
    "bg" => [:colour, :image],
    "shadow" => [:shadow]
  }

  for {prefix, kinds} <- @read_kinds, kind <- kinds do
    replaced_by = @kind_controls[{prefix, kind}]
    read_as = @by_utility[prefix]

    if replaced_by != read_as do
      raise "Styles: the #{kind} kind of the #{inspect(prefix)} prefix is read as " <>
              "#{read_as} but replaced by #{inspect(replaced_by)}"
    end
  end

  @doc """
  Splits a class attribute into the author's own classes and the override map the editor recorded.

  Returns `{authored_classes, styles}`. Anything that does not look like a generated utility stays
  in `authored_classes` untouched and in its original order.
  """
  @spec from_classes(String.t() | nil) :: {[String.t()], map()}
  def from_classes(class, opts \\ [])

  def from_classes(nil, _opts), do: {[], %{}}

  def from_classes(class, opts) when is_binary(class) do
    important? = Keyword.get(opts, :important?, false)

    class
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&{&1, parse_class(&1, important?)})
    |> settle()
    |> Enum.reduce({[], %{}}, fn
      {token, :authored}, {authored, styles} ->
        {[token | authored], styles}

      {_token, {bucket, prop, value}}, {authored, styles} ->
        {authored, put_style(styles, bucket, prop, value)}
    end)
    |> then(fn {authored, styles} -> {Enum.reverse(authored), styles} end)
  end

  # A CLASS IS READ ONLY WHEN NOTHING BESIDE IT WOULD BE LOST FOR IT. The override a class becomes is
  # written back on the next serialize, and `merge_class/3` drops every authored class that override
  # replaces — so `bg-white bg-[#000]` read as one background came back as `bg-[#000]`, and two
  # classes for one control kept only the second. Either way the class stays the author's.
  #
  # Repeated until nothing moves: a class given back to the author can be what the next one replaces.
  defp settle(entries),
    do: settle(entries, replaced_slots(for {token, :authored} <- entries, do: token))

  defp settle(entries, replaced) do
    read = Enum.frequencies(for {_token, {bucket, prop, _value}} <- entries, do: {bucket, prop})

    {settled, given_back} =
      Enum.map_reduce(entries, [], fn
        {token, {bucket, prop, _value}} = entry, given_back ->
          slot = {bucket, prop}

          case MapSet.member?(replaced, slot) or Map.fetch!(read, slot) > 1 do
            true -> {{token, :authored}, [token | given_back]}
            false -> {entry, given_back}
          end

        authored, given_back ->
          {authored, given_back}
      end)

    case given_back do
      [] -> entries
      tokens -> settle(settled, MapSet.union(replaced, replaced_slots(tokens)))
    end
  end

  defp replaced_slots(tokens),
    do: for(token <- tokens, slot <- replaced_by(token), into: MapSet.new(), do: slot)

  # AN IMPORTANT UTILITY IS STILL ONE OF OURS. `to_classes/2` writes `p-[8px]!` for a component and
  # a slot — the bang is what lets an override beat the kit's own `[&_table_.table-header]:px-4` —
  # and nothing stripped it on the way back, so the token read as a class the author typed. The
  # override was written, replaced correctly on the next edit, and never shown: set padding on any
  # kit component, save, reopen, and the field was empty over markup that carried the value.
  #
  # Only where the writer uses the bang. On a plain tag `p-[8px]!` is the author's own text and
  # lifting it would re-emit it without the bang, which changes what it means.
  #
  # AND ONLY WHAT IS WRITTEN BACK THE SAME. `bg-[url(/hero.jpg)]` read as a background came back as
  # `[background:url(/hero.jpg)]` — the shorthand, which Tailwind sorts after `bg-cover` and so
  # resets the size — and `p-[8]`, which paints nothing, came back as eight pixels of padding.
  #
  # Bang included. On a component a class WITHOUT one is the author's, not this writer's: read, it
  # came back as `text-[#e9e7ff]!`, which beats the `hover:text-white` beside it.
  defp parse_class(token, important?) do
    {variant, rest} = split_variant(candidate(token, important?))

    with bucket when not is_nil(bucket) <- bucket_for(variant),
         {^bucket, prop, value} = style <- parse_value(bucket, rest),
         class when is_binary(class) <- class_for(bucket, prop, value),
         ^token <- emphasise(class, important?) do
      style
    else
      _not_ours -> :authored
    end
  end

  defp candidate(token, true), do: String.replace_suffix(token, "!", "")
  defp candidate(token, false), do: token

  defp parse_value(bucket, rest) do
    case Map.get(@by_enum_value, rest) do
      nil -> parse_raw(bucket, rest)
      prop -> {bucket, prop, rest}
    end
  end

  defp parse_raw(bucket, "[" <> declaration = rest) do
    with true <- String.ends_with?(declaration, "]"),
         [prop, value] <- declaration |> String.trim_trailing("]") |> String.split(":", parts: 2),
         true <- prop in @raw_parse do
      {bucket, prop, unescape(value)}
    else
      _not_ours -> parse_arbitrary(bucket, rest)
    end
  end

  defp parse_raw(bucket, "grid-cols-" <> value = rest) do
    case count?(value) do
      true -> {bucket, "grid-cols", value}
      false -> parse_arbitrary(bucket, rest)
    end
  end

  defp parse_raw(bucket, rest), do: parse_arbitrary(bucket, rest)

  defp parse_arbitrary(bucket, rest) do
    with [util, "[" <> bracketed] <- split_utility(rest),
         prop when not is_nil(prop) <- Map.get(@by_utility, util),
         true <- String.ends_with?(bracketed, "]"),
         value = bracketed |> String.trim_trailing("]") |> unescape(),
         true <- read_kind?(util, value) do
      {bucket, prop, value}
    else
      _other -> :authored
    end
  end

  # A hinted value is never one this module wrote, and read back it would put `color:` in the box.
  defp read_kind?(util, value) do
    case Map.fetch(@read_kinds, util) do
      {:ok, kinds} -> is_nil(type_hint(value)) and value_kind(value, util) in kinds
      :error -> true
    end
  end

  # LONGEST FIRST, because `max-[560px]` is a prefix of `max-[560px]:hover` and splitting on the
  # first colon would read the pair as the plain breakpoint and leave `hover:` on the utility, where
  # nothing recognises it. Matching the whole known prefix also spares the raw properties a special
  # case: `[font-size:3rem]` starts with no variant at all, so it comes back whole.
  @prefixes @variants
            |> Map.values()
            |> Enum.reject(&is_nil/1)
            |> Enum.sort_by(&(-String.length(&1)))

  defp split_variant(token) do
    case String.contains?(token, ":") do
      true -> variant_prefix(token)
      false -> {nil, token}
    end
  end

  defp variant_prefix(token) do
    Enum.find_value(@prefixes, {nil, token}, fn prefix ->
      case String.starts_with?(token, prefix <> ":") do
        true ->
          {prefix,
           binary_part(token, byte_size(prefix) + 1, byte_size(token) - byte_size(prefix) - 1)}

        false ->
          false
      end
    end)
  end

  @by_variant for {bucket, name} <- @variants, not is_nil(name), into: %{}, do: {name, bucket}

  defp bucket_for(nil), do: :base
  defp bucket_for(variant), do: Map.get(@by_variant, variant)

  # `max-w-[40rem]` must split on the LAST dash before the bracket, not the first.
  defp split_utility(rest) do
    case String.split(rest, "-[", parts: 2) do
      [util, bracketed] -> [util, "[" <> bracketed]
      _other -> :no_bracket
    end
  end

  defp put_style(styles, bucket, prop, value) do
    Map.update(styles, bucket, %{prop => value}, &Map.put(&1, prop, value))
  end

  @doc """
  A `class={[…]}` expression split into the part that is ours and the part that is the author's.

  Returns `{parts, styles}` where `parts` is `list_parts/1`'s reading of the list with the
  recognised utilities taken out of its classes, or `:not_a_list` for an expression this cannot
  safely take apart — `class={@variant}`, a function call, anything that is not a literal list.

  ## Why a list is worth taking apart and `@variant` is not

  A list is the shape the HEEx guidance asks for and the shape every kit component uses, so it is
  where an override actually lands in practice. Its STRING elements are plain classes and can be
  read exactly as a string class is; everything else — `@flag && "x"`, a call, a variable — is the
  author's logic and passes through untouched, in place.

  Without this the round trip was one-way: `Serializer.computed_class/4` appended the override and
  the next parse could not see it, so a second edit nested another list and kept the first value —
  `[[["p-2", …], "w-[1000px]"], "w-[900px]"]` — two classes of equal specificity where the stale one
  can win.
  """
  @spec split_list_expr(String.t(), keyword()) :: {[part()], map()} | :not_a_list
  def split_list_expr(source, opts \\ [])

  def split_list_expr(source, opts) when is_binary(source) do
    case list_parts(source) do
      :not_a_list -> :not_a_list
      parts -> split_parts(parts, opts)
    end
  end

  def split_list_expr(_source, _opts), do: :not_a_list

  # The literal elements are read as one class attribute, so `["text-[#fff]", "text-[#000]"]` is two
  # classes for one control exactly as the same two in a string are. A class read is in no other
  # element: the same class twice is two classes for one control.
  defp split_parts(parts, opts) do
    literal = for {:classes, classes} <- parts, class <- classes, do: class
    {authored, styles} = from_classes(Enum.join(literal, " "), opts)
    read = literal -- authored

    {Enum.map(parts, &without_read(&1, read)), styles}
  end

  defp without_read({:classes, classes}, read), do: {:classes, classes -- read}
  defp without_read(logic, _read), do: logic

  @doc """
  A `class={[…]}` expression taken apart in order: `{:classes, [class]}` for each literal string
  element and `{:logic, source}` for everything the author works out at render time.

  Returns `:not_a_list` for an expression this cannot take apart — the same expressions
  `split_list_expr/2` refuses.

  ## Why the classes inside a list have to be readable and writable

  A CLASS IN A LIST IS A CLASS THE ELEMENT WEARS. The minted `pb-xxxxxxxx` that names an element to
  its own CSS rule is spliced in here when the class is an expression
  (`MishkaCmsCore.Runtime.PageBuilder.Tree.ensure_scope/2`) — flattening the list to a string to add
  it would write the literal text `@variant` into the page. So every reader of a scope and every
  writer of one comes through this and `list_expr/1`: a caller that instead rebuilt the attribute
  from the classes it could see destroyed the author's own logic, and one that could not see them
  minted a second name for an element that already had one.
  """
  @spec list_parts(String.t()) :: [part()] | :not_a_list
  def list_parts(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, list} when is_list(list) -> Enum.map(list, &list_part/1)
      _not_a_list -> :not_a_list
    end
  end

  def list_parts(_source), do: :not_a_list

  defp list_part(text) when is_binary(text),
    do: {:classes, String.split(text, ~r/\s+/, trim: true)}

  defp list_part(other), do: {:logic, Macro.to_string(other)}

  @doc """
  The `class={[…]}` expression source `parts` spell, or `nil` when nothing of them is left.

  Nothing left means the attribute goes, the same as an emptied string class: a list holding only
  the name an element has just given up is not a class.
  """
  @spec list_expr([part()]) :: String.t() | nil
  def list_expr(parts) do
    case Enum.flat_map(parts, &part_source/1) do
      [] -> nil
      sources -> "[" <> Enum.join(sources, ", ") <> "]"
    end
  end

  defp part_source({:classes, []}), do: []
  defp part_source({:classes, classes}), do: [inspect(Enum.join(classes, " "))]
  defp part_source({:logic, source}), do: [source]

  @doc """
  A `class={…}` expression's source with `classes` added to it as literals, or `nil` for one nothing
  can be added to.

  A list is extended; anything else is the author's own expression, which is not ours to take apart,
  so it becomes the first element of a list the classes join.

  ## Why the splice is read back before it is kept

  AN EXPRESSION IS NOT ALWAYS SOMETHING A COMMA CAN FOLLOW. `class={if @x, do: "a", else: "b"}` ends
  in a keyword list written without brackets, and `[if @x, do: "a", else: "b", "pb-0167f46c"]` is a
  syntax error: a page that no longer compiles and can no longer be saved, wearing a name that reads
  back as no name at all — so the element cannot be found by it, cannot give it up, and is handed a
  second one on every visit to its Custom CSS box.

  Building the source and parsing it again is the only thing that actually knows. Bracketing it is
  tried first because that is the shape every list class already has; parenthesising the author's
  expression is what rescues the keyword-list tail; and an expression neither reaches is one this
  cannot write, which is `nil` rather than a guess.
  """
  @spec add_expr_classes(String.t(), [String.t()]) :: String.t() | nil
  def add_expr_classes(source, classes) when is_binary(source) do
    case list_parts(source) do
      :not_a_list -> spliced_expr(source, classes)
      parts -> list_expr(parts ++ [{:classes, classes}])
    end
  end

  defp spliced_expr(source, classes) do
    Enum.find_value([source, "(" <> source <> ")"], fn logic ->
      spliced = list_expr([{:logic, logic}, {:classes, classes}])

      case list_parts(spliced) do
        :not_a_list -> nil
        _reads_back -> spliced
      end
    end)
  end

  @doc """
  The class attribute a node should serialize with: the author's classes followed by the compiled
  overrides. Returns `nil` when there is nothing to write, so an override-free node with no class
  keeps having no class attribute.

  Every authored class is kept unless an override in `styles` replaces it — one that would read as
  an override but has none is the author's, and stays.
  """
  @spec merge_class(String.t() | nil, map(), keyword()) :: String.t() | nil
  def merge_class(authored, styles, opts \\ []) do
    kept = String.split(authored || "", ~r/\s+/, trim: true)
    emitted = to_classes(styles, opts)

    case Enum.reject(kept, &overridden?(&1, styles)) ++ emitted do
      [] -> nil
      classes -> Enum.join(classes, " ")
    end
  end

  @doc """
  `classes` with each one that sets `prop` under a variant made important: `hover:text-white`
  becomes `hover:text-white!` when `prop` is `"color"`.

  A component's override is written important, so it beats the kit's own classes, and it beats the
  author's variants beside it just the same: a link given a colour stopped changing on hover. With
  both important, Tailwind's order decides again, and it puts the variant last.
  """
  @spec with_important_variants([String.t()], String.t()) :: [String.t()]
  def with_important_variants(classes, prop) when is_list(classes),
    do: Enum.map(classes, &important_variant(&1, prop))

  defp important_variant(class, prop) do
    with false <- String.ends_with?(class, "!"),
         at when at > 0 <- last_variant_colon(class, 0, 0, 0),
         utility = binary_part(class, at + 1, byte_size(class) - at - 1),
         true <- prop in controls_replacing(utility, :base) do
      class <> "!"
    else
      _not_a_variant_of_it -> class
    end
  end

  # Where the variants end: the last colon outside brackets, so `max-[560px]:hover:text-white` is
  # `text-white` and `[font-size:2rem]` has no variant at all. `0` when there is none.
  defp last_variant_colon(<<>>, _at, _depth, found), do: found

  defp last_variant_colon(<<char, rest::binary>>, at, depth, found) when char in ~c"[(",
    do: last_variant_colon(rest, at + 1, depth + 1, found)

  defp last_variant_colon(<<char, rest::binary>>, at, depth, found) when char in ~c"])",
    do: last_variant_colon(rest, at + 1, depth - 1, found)

  defp last_variant_colon(<<?:, rest::binary>>, at, 0, _found),
    do: last_variant_colon(rest, at + 1, 0, at)

  defp last_variant_colon(<<_char, rest::binary>>, at, depth, found),
    do: last_variant_colon(rest, at + 1, depth, found)

  # AN OVERRIDE MUST REPLACE, NOT JOIN. `from_classes/1` only recognises the shapes this module
  # emits — `bg-[#fff]` and the `@enums` words — so an ordinary hand-written utility like
  # `bg-indigo-600` is classified `:authored` and kept. Appending `bg-[#17161a]` beside it then
  # changes nothing a reader can see: two single-class selectors tie on specificity and the winner is
  # decided by which rule the stylesheet happens to list last, which is the compiled bundle.
  #
  # That is why setting a background looked broken while setting it on `:hover` looked fine — a
  # hover override compiles to `.hover\:bg-\[…\]:hover`, a two-part selector that outranks the tie
  # instead of joining it. The state was never the difference; the collision was.
  defp overridden?(token, styles) when is_map(styles) do
    Enum.any?(replaced_by(token), fn {bucket, prop} ->
      case Map.get(styles, bucket) do
        props when is_map(props) -> Map.has_key?(props, prop)
        _none -> false
      end
    end)
  end

  defp overridden?(_token, _styles), do: false

  # The `{bucket, control}` pairs whose override replaces `token`, with or without its bang.
  defp replaced_by(token) do
    {variant, rest} = token |> String.replace_suffix("!", "") |> split_variant()

    case bucket_for(variant) do
      nil -> []
      bucket -> rest |> controls_replacing(bucket) |> Enum.map(&{bucket, &1})
    end
  end

  # A class left to the author in a control's own spelling — `flex` beside `grid`, or a
  # `[font-size:2rem]` beside a `text-[14px]` — is still that control's, and goes when it is set. A
  # utility's own control is among the ones the utility gives way to, so only a word and a raw
  # property are read as one.
  defp controls_replacing(rest, bucket) do
    word = word_control(rest)

    case utility_of(rest) do
      nil -> Enum.uniq(word ++ raw_control(bucket, rest))
      {util, value} -> Enum.uniq(word ++ utility_controls(util, value))
    end
  end

  defp raw_control(bucket, rest) do
    case parse_value(bucket, rest) do
      {_bucket, prop, _value} -> [prop]
      :authored -> []
    end
  end

  # The display utilities the Display control replaces without offering them.
  @display_utilities ~w(inline inline-block flow-root inline-flex inline-grid contents table
                        inline-table list-item hidden)

  defp word_control(rest) when rest in @display_utilities, do: ["display"]
  defp word_control(rest), do: List.wrap(Map.get(@by_enum_value, rest))

  # TAILWIND SPELLS SEVERAL PROPERTIES THE SAME WAY. `text-` is colour, size AND alignment;
  # `border-` is colour and width. Dropping every `text-*` because a colour was set would take
  # `text-lg` and `text-center` with it, so for those the class has to be the kind of value the
  # override is (`@kind_controls`). Everything else owns its utility outright and any value collides.
  defp utility_controls(util, value) when is_map_key(@prefix_kinds, util) do
    case Map.get(@kind_controls, {util, class_kind(util, value)}) do
      nil -> []
      control -> [control]
    end
  end

  defp utility_controls(util, _value), do: Map.get(@superseded_by, util, [])

  # What follows the prefix: `[14px]`, `[#fff]/50`, `indigo-600/50`, `5xl`, or nothing at all.
  defp class_kind(util, "[" <> rest) do
    case :binary.matches(rest, "]") do
      [] ->
        :other

      closes ->
        rest |> binary_part(0, closes |> List.last() |> elem(0)) |> unescape() |> value_kind(util)
    end
  end

  defp class_kind(util, word) do
    case word |> String.split("/", parts: 2) |> hd() |> palette_colour?() do
      true -> :colour
      false -> word_kind(util)
    end
  end

  # A word that is not a colour is the prefix's own scale — `text-5xl`, `border-2`, `bg-cover` — and
  # no control here replaces it: Tailwind already orders `[font-size:…]` after `text-5xl`, and taking
  # the class would take its line height with it. Every `shadow-*` word but a colour is a shadow.
  defp word_kind("shadow"), do: :shadow
  defp word_kind(_util), do: :other

  # Tailwind's palette words — `white`, `black`, `transparent`, `current`, `inherit`, or a
  # `family-shade` pair like `indigo-600`.
  defp palette_colour?(word) do
    word in ~w(white black transparent current inherit) or
      Regex.match?(~r/^[a-z]+-\d{2,3}$/, word)
  end

  # The kind of an arbitrary value under `util`, decided the way Tailwind decides it.
  defp value_kind(value, util) do
    {fallback, kinds} = Map.fetch!(@prefix_kinds, util)

    case type_hint(value) do
      nil -> inferred_kind(value, kinds, fallback)
      hint -> Enum.find_value(kinds, fallback, fn {kind, types} -> hint in types and kind end)
    end
  end

  # `length` in `length:var(--x)`: lower-case letters and dashes, then a colon.
  defp type_hint(value), do: type_hint(value, 0)

  defp type_hint(value, at) when at > 0 and binary_part(value, at, 1) == ":",
    do: binary_part(value, 0, at)

  defp type_hint(value, at) when byte_size(value) > at do
    case :binary.at(value, at) do
      char when char in ?a..?z or char == ?- -> type_hint(value, at + 1)
      _other -> nil
    end
  end

  defp type_hint(_value, _at), do: nil

  defp inferred_kind("var(" <> _rest, _kinds, fallback), do: fallback

  defp inferred_kind(value, kinds, fallback) do
    Enum.find_value(kinds, fallback, fn {kind, types} ->
      Enum.any?(types, &type?(&1, value)) and kind
    end)
  end

  defp type?("color", value), do: colour?(value)
  defp type?("length", value), do: length?(value)
  defp type?("percentage", value), do: percentage?(value)
  defp type?("number", value), do: number?(value)
  defp type?("url", value), do: url?(value)
  defp type?("image", value), do: image?(value)
  defp type?("position", value), do: position?(value)
  defp type?("bg-size", value), do: bg_size?(value)

  defp type?("absolute-size", value),
    do: value in ~w(xx-small x-small small medium large x-large xx-large xxx-large)

  defp type?("relative-size", value), do: value in ~w(larger smaller)

  defp type?("line-width", value) do
    value
    |> segments(" ")
    |> Enum.all?(&(length?(&1) or number?(&1) or &1 in ~w(thin medium thick)))
  end

  defp type?(_hint_only, _value), do: false

  @named_colours ~w(
    black silver gray white maroon red purple fuchsia green lime olive yellow navy blue teal
    aqua aliceblue antiquewhite aquamarine azure beige bisque blanchedalmond blueviolet brown
    burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue
    darkcyan darkgoldenrod darkgray darkgreen darkgrey darkkhaki darkmagenta darkolivegreen
    darkorange darkorchid darkred darksalmon darkseagreen darkslateblue darkslategray
    darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue
    firebrick floralwhite forestgreen gainsboro ghostwhite gold goldenrod greenyellow grey
    honeydew hotpink indianred indigo ivory khaki lavender lavenderblush lawngreen lemonchiffon
    lightblue lightcoral lightcyan lightgoldenrodyellow lightgray lightgreen lightgrey lightpink
    lightsalmon lightseagreen lightskyblue lightslategray lightslategrey lightsteelblue
    lightyellow limegreen linen magenta mediumaquamarine mediumblue mediumorchid mediumpurple
    mediumseagreen mediumslateblue mediumspringgreen mediumturquoise mediumvioletred
    midnightblue mintcream mistyrose moccasin navajowhite oldlace olivedrab orange orangered
    orchid palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru pink
    plum powderblue rebeccapurple rosybrown royalblue saddlebrown salmon sandybrown seagreen
    seashell sienna skyblue slateblue slategray slategrey snow springgreen steelblue tan thistle
    tomato turquoise violet wheat whitesmoke yellowgreen transparent currentcolor canvas
    canvastext linktext visitedtext activetext buttonface buttontext buttonborder field
    fieldtext highlight highlighttext selecteditem selecteditemtext mark marktext graytext
    accentcolor accentcolortext
  )

  @colour_functions ~w(rgb( rgba( hsl( hsla( hwb( color( lab( lch( oklab( oklch( light-dark(
                       color-mix( --alpha()

  defp colour?("#" <> _hex), do: true

  defp colour?(value) do
    value = String.downcase(value)
    String.starts_with?(value, @colour_functions) or value in @named_colours
  end

  @length_units ~w(cm mm q in pc pt px em ex ch rem lh rlh vw vh vmin vmax vb vi svw svh lvw lvh
                   dvw dvh cqw cqh cqi cqb cqmin cqmax)

  defp length?(value) do
    case Regex.run(~r/^[+-]?\d*\.?\d+(?:e[+-]?\d+)?([a-z]+)$/i, value) do
      [_length, unit] -> String.downcase(unit) in @length_units
      nil -> String.starts_with?(value, "--spacing(") or math?(value)
    end
  end

  defp number?(value),
    do: Regex.match?(~r/^[+-]?\d*\.?\d+(?:e[+-]?\d+)?$/i, value) or math?(value)

  defp percentage?(value),
    do: Regex.match?(~r/^[+-]?\d*\.?\d+(?:e[+-]?\d+)?%$/i, value) or math?(value)

  @math_functions ~w(calc min max clamp mod rem sin cos tan asin acos atan atan2 pow sqrt hypot log
                     exp round)

  defp math?(value), do: Enum.any?(@math_functions, &String.contains?(value, &1 <> "("))

  defp url?(value), do: String.starts_with?(value, "url(") and String.ends_with?(value, ")")

  @image_functions ~w(linear-gradient( radial-gradient( conic-gradient( repeating-linear-gradient(
                      repeating-radial-gradient( repeating-conic-gradient( element( image(
                      cross-fade( image-set()

  defp image?(value) do
    case value |> segments(",") |> Enum.reject(&String.starts_with?(&1, "var(")) do
      [] -> false
      images -> Enum.all?(images, &(url?(&1) or String.starts_with?(&1, @image_functions)))
    end
  end

  defp position?(value) do
    case value |> segments(" ") |> Enum.reject(&String.starts_with?(&1, "var(")) do
      [] -> false
      parts -> Enum.all?(parts, &(&1 in ~w(center top right bottom left) or length_ish?(&1)))
    end
  end

  defp bg_size?(value) do
    sizes = Enum.map(segments(value, ","), &segments(&1, " "))

    Enum.all?(sizes, &(length(&1) in 1..2)) and
      Enum.any?(sizes, fn
        [keyword] when keyword in ~w(cover contain) -> true
        parts -> Enum.all?(parts, &(&1 == "auto" or length_ish?(&1)))
      end)
  end

  defp length_ish?(value), do: length?(value) or percentage?(value)

  # `value` split on `separator` where no bracket is open, the way Tailwind splits a value into its
  # parts: `rgb(0 0 0) url(a)` is two parts, not four.
  defp segments(value, separator) do
    case String.contains?(value, separator) do
      true -> split_outside_groups(value, separator)
      false -> [value]
    end
  end

  defp split_outside_groups(value, separator) do
    {parts, current, _depth} =
      value
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        "(", {parts, current, depth} -> {parts, current <> "(", depth + 1}
        ")", {parts, current, depth} -> {parts, current <> ")", depth - 1}
        ^separator, {parts, current, 0} -> {[current | parts], "", 0}
        char, {parts, current, depth} -> {parts, current <> char, depth}
      end)

    Enum.reverse([current | parts])
  end

  # The utility a token starts with and the value it carries — `bg-indigo-600` is `{"bg",
  # "indigo-600"}`. Longest match first, so `min-h-screen` is `min-h` rather than `min`. Only the
  # utilities that start with the token's first word can match it.
  @utilities_by_word @utilities
                     |> Map.values()
                     |> Enum.sort_by(&(-String.length(&1)))
                     |> Enum.group_by(&(&1 |> String.split("-", parts: 2) |> hd()))

  defp utility_of(rest) do
    @utilities_by_word
    |> Map.get(first_word(rest), [])
    |> Enum.find_value(fn util ->
      case rest do
        ^util -> {util, ""}
        _prefixed -> String.starts_with?(rest, util <> "-") && {util, drop_prefix(rest, util)}
      end
    end)
  end

  defp drop_prefix(rest, util),
    do: binary_part(rest, byte_size(util) + 1, byte_size(rest) - byte_size(util) - 1)

  defp first_word(rest), do: rest |> String.split("-", parts: 2) |> hd()
end
