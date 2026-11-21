#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static GtkWidget *win, *iso_lbl, *dev_combo, *bar, *status, *write_btn, *refresh_btn;
static char iso_path[4096];
static char dev_path[256];
static guint64 iso_size;
static GIOChannel *chan;
static guint chan_id;
static guint64 last_done;

static void quiet_log(const gchar *d, GLogLevelFlags l, const gchar *m, gpointer u)
{
    (void)d; (void)l; (void)m; (void)u;
}

static void set_status(const char *s)
{
    gtk_label_set_text(GTK_LABEL(status), s);
}

static void refresh_devices(void)
{
    FILE *p = popen("lsblk -dno NAME,SIZE,TYPE,RM,MODEL 2>/dev/null", "r");
    char line[512];
    gtk_combo_box_text_remove_all(GTK_COMBO_BOX_TEXT(dev_combo));
    if (!p) return;
    while (fgets(line, sizeof line, p)) {
        char name[64] = "", size[64] = "", type[32] = "", rm[16] = "";
        char model[256] = "";
        int n = sscanf(line, "%63s %63s %31s %15s %255[^\n]", name, size, type, rm, model);
        if (n < 4) continue;
        if (strcmp(type, "disk") != 0) continue;
        char label[512];
        snprintf(label, sizeof label, "/dev/%s   %s   %s%s", name, size, model,
                 strcmp(rm, "1") == 0 ? "  [USB]" : "");
        gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(dev_combo), label);
    }
    pclose(p);
    if (gtk_combo_box_get_active(GTK_COMBO_BOX(dev_combo)) < 0)
        gtk_combo_box_set_active(GTK_COMBO_BOX(dev_combo), 0);
}

static gboolean busy_check(const char *dev)
{
    char cmd[512], out[1024] = "";
    FILE *p;
    snprintf(cmd, sizeof cmd, "lsblk -no MOUNTPOINT %s 2>/dev/null", dev);
    p = popen(cmd, "r");
    if (!p) return FALSE;
    while (fgets(out, sizeof out, p)) {
        char *s = out;
        while (*s == ' ') s++;
        if (!strncmp(s, "/", 1)) {
            pclose(p);
            return TRUE;
        }
    }
    pclose(p);
    return FALSE;
}

static gboolean on_chan(GIOChannel *c, GIOCondition cond, gpointer data)
{
    char buf[512];
    gsize n = 0;
    if (cond & G_IO_IN) {
        while (g_io_channel_read_chars(c, buf, sizeof buf - 1, &n, NULL) == G_IO_STATUS_NORMAL && n) {
            buf[n] = 0;
            char *s = strstr(buf, "bytes");
            if (s && iso_size) {
                while (s > buf && s[-1] != '\n') s--;
                guint64 d = g_ascii_strtoull(s, NULL, 10);
                if (d > last_done && d <= iso_size) {
                    last_done = d;
                    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(bar), (double)d / (double)iso_size);
                }
            }
        }
    }
    if (cond & (G_IO_HUP | G_IO_ERR)) {
        int st = 0;
        g_spawn_close_pid(GPOINTER_TO_INT(data));
        (void)st;
        g_io_channel_unref(chan);
        chan = NULL;
        chan_id = 0;
        gtk_widget_set_sensitive(write_btn, TRUE);
        gtk_widget_set_sensitive(refresh_btn, TRUE);
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(bar), 1.0);
        set_status("Done. You can remove the drive.");
        return FALSE;
    }
    return TRUE;
}

static void do_write(void)
{
    char cmd[8192];
    char *argv[4];
    int out_fd;
    GPid pid;
    GError *err = NULL;
    gchar *quoted;

    if (!iso_path[0]) { set_status("Choose an ISO file first."); return; }
    if (!dev_path[0]) { set_status("Choose a disk."); return; }
    if (busy_check(dev_path)) {
        set_status("That disk is in use by the running system.");
        return;
    }
    quoted = g_shell_quote(iso_path);
    snprintf(cmd, sizeof cmd, "dd if=%s of=%s bs=4M conv=fsync status=progress 2>&1", quoted, dev_path);
    g_free(quoted);
    argv[0] = (char *)"pkexec";
    argv[1] = (char *)"sh";
    argv[2] = (char *)"-c";
    argv[3] = cmd;
    if (!g_find_program_in_path("pkexec")) {
        set_status("pkexec is missing. Start the program with sudo.");
        return;
    }
    if (!g_spawn_async_with_pipes(NULL, argv, NULL,
            G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_SEARCH_PATH, NULL, NULL, &pid,
            NULL, &out_fd, NULL, &err)) {
        set_status(err->message);
        g_error_free(err);
        return;
    }
    gtk_widget_set_sensitive(write_btn, FALSE);
    gtk_widget_set_sensitive(refresh_btn, FALSE);
    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(bar), 0.0);
    last_done = 0;
    set_status("Writing...");
    chan = g_io_channel_unix_new(out_fd);
    g_io_channel_set_flags(chan, G_IO_FLAG_NONBLOCK, NULL);
    g_io_channel_set_encoding(chan, NULL, NULL);
    chan_id = g_io_add_watch(chan, G_IO_IN | G_IO_HUP | G_IO_ERR, on_chan, GINT_TO_POINTER(pid));
}

static void on_confirm(GtkMessageDialog *d, gint r, gpointer data)
{
    gtk_widget_destroy(GTK_WIDGET(d));
    if (r == GTK_RESPONSE_YES) do_write();
}

static void on_write(GtkWidget *w, gpointer data)
{
    GtkWidget *d;
    char msg[1024];
    const char *lbl = gtk_combo_box_text_get_active_text(GTK_COMBO_BOX_TEXT(dev_combo));
    if (!lbl) { set_status("Choose a disk."); return; }
    sscanf(lbl, "%255s", dev_path);
    if (!iso_path[0]) { set_status("Choose an ISO file first."); return; }
    snprintf(msg, sizeof msg, "All data on %s will be erased.\nWrite %s to it?", dev_path, iso_path);
    d = gtk_message_dialog_new(GTK_WINDOW(win), GTK_DIALOG_MODAL, GTK_MESSAGE_WARNING,
                               GTK_BUTTONS_NONE, "%s", msg);
    gtk_dialog_add_button(GTK_DIALOG(d), "Cancel", GTK_RESPONSE_CANCEL);
    gtk_dialog_add_button(GTK_DIALOG(d), "Write", GTK_RESPONSE_YES);
    g_signal_connect(d, "response", G_CALLBACK(on_confirm), NULL);
    gtk_widget_show_all(d);
}

static void on_iso(GtkFileChooser *c, gpointer data)
{
    char *p = gtk_file_chooser_get_filename(c);
    struct stat st;
    if (!p) return;
    snprintf(iso_path, sizeof iso_path, "%s", p);
    g_free(p);
    if (stat(iso_path, &st) == 0) iso_size = st.st_size;
    gtk_button_set_label(GTK_BUTTON(iso_lbl), strrchr(iso_path, '/') ? strrchr(iso_path, '/') + 1 : iso_path);
}

int main(int argc, char **argv)
{
    GtkWidget *grid, *hdr, *sub, *iso_btn, *dev_lbl;

    gtk_init(&argc, &argv);
    g_log_set_handler("GLib", G_LOG_LEVEL_CRITICAL, quiet_log, NULL);
    win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(win), "Centtrix USB writer");
    gtk_window_set_default_size(GTK_WINDOW(win), 640, 380);
    gtk_container_set_border_width(GTK_CONTAINER(win), 18);
    g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);

    grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 12);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 14);
    gtk_container_add(GTK_CONTAINER(win), grid);

    hdr = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(hdr), "<span size='x-large' weight='bold'>Write Centtrix to a USB drive</span>");
    gtk_widget_set_halign(hdr, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), hdr, 0, 0, 2, 1);

    sub = gtk_label_new("Pick the ISO image, choose the target disk and press Write. Everything on the disk is erased.");
    gtk_label_set_line_wrap(GTK_LABEL(sub), TRUE);
    gtk_widget_set_halign(sub, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), sub, 0, 1, 2, 1);

    iso_btn = gtk_file_chooser_button_new("Choose the Centtrix ISO", GTK_FILE_CHOOSER_ACTION_OPEN);
    iso_lbl = gtk_button_new_with_label("No ISO selected");
    gtk_widget_set_sensitive(iso_lbl, FALSE);
    g_signal_connect(iso_btn, "file-set", G_CALLBACK(on_iso), NULL);
    {
        GtkFileFilter *f = gtk_file_filter_new();
        gtk_file_filter_set_name(f, "ISO images");
        gtk_file_filter_add_pattern(f, "*.iso");
        gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(iso_btn), f);
    }
    gtk_grid_attach(GTK_GRID(grid), iso_btn, 0, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), iso_lbl, 1, 2, 1, 1);

    dev_lbl = gtk_label_new("Disk");
    gtk_widget_set_halign(dev_lbl, GTK_ALIGN_START);
    dev_combo = gtk_combo_box_text_new();
    refresh_btn = gtk_button_new_with_label("Rescan");
    g_signal_connect(refresh_btn, "clicked", G_CALLBACK(refresh_devices), NULL);
    gtk_grid_attach(GTK_GRID(grid), dev_lbl, 0, 3, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), dev_combo, 1, 3, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), refresh_btn, 0, 4, 1, 1);

    bar = gtk_progress_bar_new();
    gtk_grid_attach(GTK_GRID(grid), bar, 0, 5, 2, 1);

    status = gtk_label_new("Ready.");
    gtk_widget_set_halign(status, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), status, 0, 6, 2, 1);

    write_btn = gtk_button_new_with_label("Write");
    g_signal_connect(write_btn, "clicked", G_CALLBACK(on_write), NULL);
    gtk_grid_attach(GTK_GRID(grid), write_btn, 0, 7, 2, 1);

    refresh_devices();
    gtk_widget_show_all(win);
    gtk_main();
    return 0;
}
