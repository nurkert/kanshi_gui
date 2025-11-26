#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* menu_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void menu_action_cb(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->menu_channel == nullptr) {
    return;
  }
  const gchar* name = g_action_get_name(G_ACTION(action));
  FlValue* value = fl_value_new_string(name);
  fl_method_channel_invoke_method(self->menu_channel, "select", value, nullptr, nullptr, nullptr);
  fl_value_unref(value);
}

static void setup_menu(MyApplication* self, GtkWindow* window, GtkHeaderBar* header_bar, FlView* view) {
  GActionEntry entries[] = {
      {"saveRestart", menu_action_cb, nullptr, nullptr, nullptr},
      {"saveProfiles", menu_action_cb, nullptr, nullptr, nullptr},
      {"reload", menu_action_cb, nullptr, nullptr, nullptr},
      {"enableAll", menu_action_cb, nullptr, nullptr, nullptr},
      {"restartKanshi", menu_action_cb, nullptr, nullptr, nullptr},
      {"restoreBackup", menu_action_cb, nullptr, nullptr, nullptr},
      {"showLogs", menu_action_cb, nullptr, nullptr, nullptr},
      {"showHelp", menu_action_cb, nullptr, nullptr, nullptr},
  };
  g_action_map_add_action_entries(G_ACTION_MAP(self), entries, G_N_ELEMENTS(entries), self);

  g_autoptr(GMenu) file_menu = g_menu_new();
  g_menu_append(file_menu, "Save & restart kanshi", "app.saveRestart");
  g_menu_append(file_menu, "Save profiles only", "app.saveProfiles");
  g_menu_append(file_menu, "Reload Outputs & Profiles", "app.reload");

  g_autoptr(GMenu) actions_menu = g_menu_new();
  g_menu_append(actions_menu, "Enable all displays", "app.enableAll");
  g_menu_append(actions_menu, "Restart kanshi", "app.restartKanshi");
  g_menu_append(actions_menu, "Restore & apply backup", "app.restoreBackup");
  g_menu_append(actions_menu, "Show logs", "app.showLogs");

  g_autoptr(GMenu) help_menu = g_menu_new();
  g_menu_append(help_menu, "Show tips", "app.showHelp");

  g_autoptr(GMenu) menubar = g_menu_new();
  g_menu_append_submenu(menubar, "File", G_MENU_MODEL(file_menu));
  g_menu_append_submenu(menubar, "Actions", G_MENU_MODEL(actions_menu));
  g_menu_append_submenu(menubar, "Help", G_MENU_MODEL(help_menu));

  GtkWidget* menu_bar_widget = gtk_menu_bar_new_from_model(G_MENU_MODEL(menubar));
  gtk_widget_show(menu_bar_widget);

  if (header_bar != nullptr) {
    gtk_header_bar_pack_start(header_bar, menu_bar_widget);
  } else {
    GtkWidget* content_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(window), content_box);
    gtk_box_pack_start(GTK_BOX(content_box), menu_bar_widget, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(content_box), GTK_WIDGET(view), TRUE, TRUE, 0);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  GtkHeaderBar* header_bar = nullptr;

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "kanshi_gui");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "kanshi_gui");
  }

  gtk_window_set_default_size(window, 1280, 720);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(fl_view_get_engine(view));
  FlStandardMethodCodec* codec = fl_standard_method_codec_new();
  self->menu_channel = fl_method_channel_new(messenger, "kanshi_gui/native_menu",
                                             FL_METHOD_CODEC(codec));
  g_object_unref(codec);

  setup_menu(self, window, use_header_bar ? header_bar : nullptr, view);

  if (!gtk_widget_get_parent(GTK_WIDGET(view))) {
    gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  }

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->menu_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->menu_channel = nullptr;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
