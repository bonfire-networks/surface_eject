defmodule Bonfire.UI.Common.ReusableModalLive do
  use Bonfire.UI.Common.Web, :live_component
  alias Bonfire.UI.Common.ReusableModalLive

  @moduledoc """
  The classic **modal**
  """

  @default_modal_id "modal"

  # make sure to keep these and the Surface props in sync
  @default_assigns [
    title_text: nil,
    title_class: nil,
    modal_class: "",
    wrapper_class: nil,
    action_btns_wrapper_class: nil,
    cancel_btn_class: nil,
    cancel_label: nil,
    show: false,
    form_opts: %{},
    no_actions: false,
    no_header: false,
    no_backdrop: false,
    overflow: false,
    image_preview: false,
    xl: false,
    modal_assigns: [],
    opts: [],
    autocomplete: [],
    default: nil,
    open_btn: nil,
    action_btns: nil,
    cancel_btn: nil,
    title: nil
  ]

  live_attr :title_text, :string, default: nil, doc: "The title of the modal. Only used if no title slot is passed."

  live_attr :image_preview, :boolean, default: false, doc: "If the modal is a preview of an image, set this to true."

  live_attr :title_class, :css_class, default: nil, doc: "The classes of the title of the modal"

  live_attr :modal_class, :css_class, default: "", doc: "The classes of the modal."

  live_attr :wrapper_class, :css_class, default: nil, doc: "The classes of the modal wrapper."

  live_attr :action_btns_wrapper_class, :css_class, default: nil, doc: "The classes around the action/submit button(s) on the modal"

  live_attr :cancel_btn_class, :css_class, default: nil, doc: "The classes of the close/cancel button on the modal. Only used if no close_btn slot is passed."

  live_attr :cancel_label, :string, default: nil

  live_attr :show, :boolean, default: false, doc: "Force modal to be open"

  # prop no_form, :boolean, default: false

  live_attr :form_opts, :map, default: %{}

  live_attr :no_actions, :boolean, default: false, doc: "Optional prop to hide the actions at the bottom of the modal"

  live_attr :no_header, :boolean, default: false, doc: "Optional prop to hide the header at the top of the modal"

  live_attr :no_backdrop, :boolean, default: false
  live_attr :overflow, :boolean, default: false

  live_attr :modal_assigns, :any, default: [], doc: "Additional assigns to pass on to the optional modal sub-component"

  live_attr :opts, :keyword, default: [], doc: "Additional attributes to add onto the modal wrapper"

  live_attr :autocomplete, :list, default: []

  live_attr :value, :any, default: nil, internal: true

  live_attr :xl, :boolean, default: false, doc: "Optional prop to make the modal wider"

  
  
  
  
  

  def mount(socket) do
    # debug("mounting")
    # need this because ReusableModalLive used in Phoenix HEEX layout doesn't set Surface defaults
    {:ok,
     socket
     |> assign(default_assigns())}
  end

  def default_assigns do
    @default_assigns
  end

  def modal_id(assigns) do
    e(assigns, :reusable_modal_id, nil) ||
      if(e(assigns, :__context__, :sticky, nil) || e(assigns, :sticky, nil),
        do: "persistent_modal",
        else: @default_modal_id
      )
  end

  def set(assigns, reusable_modal_id \\ nil, opts \\ []) do
    maybe_set_assigns(
      e(
        assigns,
        :reusable_modal_component,
        ReusableModalLive
      ),
      reusable_modal_id || modal_id(assigns),
      assigns,
      opts
    )

    # case assigns[:root_assigns] do
    #   root_assigns when is_list(root_assigns) and root_assigns !=[] ->
    #     send_self(assigns[:root_assigns])

    #   _ -> nil
    # end
  end

  defp maybe_set_assigns(component, reusable_modal_id, assigns, opts \\ [])

  defp maybe_set_assigns(_component, "media_player_modal", assigns, opts) do
    # TODO: forward opts (eg for PID)
    # TODO: detect if we're already in the sticky view
    # debug(assigns, "try sending to media player")
    Bonfire.UI.Common.PersistentLive.maybe_send(assigns, {:media_player, assigns})
  end

  defp maybe_set_assigns(component, reusable_modal_id, assigns, opts) do
    # debug(assigns, "try sending to reusable modal")
    maybe_send_update(
      component,
      reusable_modal_id,
      assigns,
      opts
    )
  end

  def handle_event("prompt_external_link", %{"url" => url}, socket) do
    set(
      show: true,
      modal_assigns: [
        modal_component: LinkLive,
        to: url,
        label: url,
        external_link_warnings: true,
        class: "link font-mono"
      ],
      sticky: e(assigns(socket), :__context__, :sticky, nil)
    )

    pid = self()

    apply_task(
      :start_async,
      fn ->
        debug("attempt to unshorten")

        final_url =
          Cache.maybe_apply_cached({Unfurl, :unshorten!}, url, fallback_return: nil)
          |> debug("final_url")

        if final_url != url do
          debug(final_url, "urls are different")

          set(
            [
              show: true,
              modal_assigns: [
                modal_component: LinkLive,
                to: final_url,
                label: "#{url} (redirects to #{final_url})",
                external_link_warnings: true,
                class: "link font-mono"
              ],
              sticky: e(assigns(socket), :__context__, :sticky, nil)
            ],
            nil,
            pid: pid
          )
        end
      end,
      socket: socket,
      id: "unshorten"
    )

    {:noreply, socket}
  end

  def handle_event("close-key", %{"key" => "Escape"} = _attrs, socket) do
    handle_event("close", %{}, socket)
  end

  def handle_event("close-key", %{"key" => _}, socket) do
    # ignore any other key
    {:noreply, socket}
  end

  def handle_event("close", _, socket) do
    debug(
      "reset all assigns to defaults so they don't accidentally get re-used in a different modal"
    )

    {:noreply, assign(socket, [show: false] ++ default_assigns())}
  end
end
