// Virtua Tennis 3 VR for Meta Quest. All of the game runs natively
// (libmain.so, see games/vt3/src/android_main.c); this only checks that the
// player's game files are there and loads the libraries.
//
// The game's files (the folder holding vt3_Lindbergh, shader and lib) are looked for, as
// android_main.c does:
//   /sdcard/Android/data/org.lindbergh.vt3.vr/files   (where a build with
//        the game inside unpacks it; adb cannot make folders there)
//   /sdcard/VirtuaTennis3              (where players copy it; needs
//        all-files access, which the app asks for when it finds no game)
// The release APK holds the game's code translated from one exact vt3_Lindbergh_HD
// (R.string.elf_sha256); any other version would not run, so it is checked
// here first. Without a usable game the app writes HOW-TO-ADD-THE-GAME.txt
// into its folder and closes.
package org.lindbergh.vt3;

import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.provider.Settings;
import android.util.Log;
import android.widget.Toast;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.Arrays;
import org.libsdl.app.SDLActivity;

public class VirtuaTennis3VR extends SDLActivity {
    private static final String TAG = "VirtuaTennis3VR";
    private String problem;     /* null: the game is ready */

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        problem = checkGame();
        super.onCreate(savedInstanceState);
        if (problem != null) {
            Toast.makeText(this, problem, Toast.LENGTH_LONG).show();
            finish();
        }
    }

    @Override
    public void loadLibraries() {
        if (problem != null) throw new RuntimeException(problem);   /* SDL then starts nothing */
        super.loadLibraries();
    }

    @Override
    protected String[] getLibraries() {
        return new String[] { "SDL2", "openal", "openxr_loader", "main" };
    }

    @Override
    protected String[] getArguments() {
        String path = getIntent().getBooleanExtra("lindbergh.require_private_game", false) ?
                getIntent().getStringExtra("lindbergh.private_game") : null;
        return path == null ? super.getArguments() : new String[] { "--private-game", path };
    }

    private String checkGame() {
        File own = getExternalFilesDir(null);
        // Diagnostics must never silently run against the player's shared tree.
        // Check in the real app process: shell-readable storage is insufficient.
        if (getIntent().getBooleanExtra("lindbergh.require_private_game", false)) {
            String path = getIntent().getStringExtra("lindbergh.private_game");
            if (path == null || !path.matches(java.util.regex.Pattern.quote(getFilesDir().getAbsolutePath()) +
                    "/\\.codex-xr-[0-9a-f]{32}")) return "Invalid private diagnostic path";
            own = new File(path);
            File elf = new File(own, "vt3_Lindbergh/vt3_Lindbergh_HD");
            File env = new File(own, "vt3_Lindbergh/env.txt");
            File fs = new File(own, "shader");
            File drv = new File(own, "lib");
            if (!elf.canRead() || !env.canRead() || !fs.isDirectory() || fs.list() == null ||
                    !drv.isDirectory() || drv.list() == null ||
                    !getString(R.string.elf_sha256).trim().equalsIgnoreCase(sha256(elf))) {
                String error = "Private game diagnostic refused: app cannot read the staged game/config.";
                Log.e(TAG, error);
                return error;
            }
            Log.i(TAG, "private game verified: " + elf + ", env sha256 " + sha256(env));
            return null;
        }
        try {   /* a build with the game inside unpacks it itself, after this */
            if (Arrays.asList(getAssets().list("")).contains("game.files")) return null;
        } catch (Exception e) { }

        File shared = new File(Environment.getExternalStorageDirectory(), "VirtuaTennis3");
        File elf = null;
        for (File base : new File[] { own, shared }) {
            File f = base == null ? null : new File(base, "vt3_Lindbergh/vt3_Lindbergh_HD");
            if (f != null && f.canRead()) { elf = f; break; }
        }
        String msg = null;
        if (elf == null) {
            if (!Environment.isExternalStorageManager()) {
                msg = "Allow Virtua Tennis 3 VR to access all files, copy the game's vt3_Lindbergh, shader and lib " +
                      "folders to " + shared + ", then start it again.";
                askForFileAccess();
            } else {
                msg = "Game files not found: copy the game's vt3_Lindbergh, shader and lib folders to " + shared;
            }
        } else {
            String want = getString(R.string.elf_sha256).trim();
            String have = sha256(elf);
            Log.i(TAG, "game: " + elf + ", vt3_Lindbergh_HD " + have);
            if (!want.isEmpty() && !want.equalsIgnoreCase(have)) {
                msg = "This is a different version of the game (vt3_Lindbergh_HD " + have.substring(0, 12) +
                      "), the app needs vt3_Lindbergh_HD " + want.substring(0, 12) + ".";
            }
        }
        writeHelp(own, msg);
        if (msg != null) Log.e(TAG, msg);
        return msg;
    }

    /* Called from the game (host_xr.c): the settings panel's "Reset game".
     * Restart starts it again once this process is gone. */
    public void restartGame() {
        Log.i(TAG, "reset: starting the game again");
        Intent again = new Intent(this, Restart.class);
        again.putExtra(Restart.PID, android.os.Process.myPid());
        again.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(again);
        android.os.Process.killProcess(android.os.Process.myPid());
    }

    private void askForFileAccess() {
        try {
            startActivity(new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                     Uri.parse("package:" + getPackageName())));
        } catch (Exception e) {
            Log.w(TAG, "no all-files access screen: " + e);
        }
    }

    private static String sha256(File f) {
        try (InputStream in = new FileInputStream(f)) {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] buf = new byte[1 << 16];
            for (int n; (n = in.read(buf)) > 0; ) md.update(buf, 0, n);
            StringBuilder s = new StringBuilder();
            for (byte b : md.digest()) s.append(String.format("%02x", b));
            return s.toString();
        } catch (Exception e) {
            return "unreadable";
        }
    }

    private void writeHelp(File own, String msg) {
        if (own == null) return;
        File help = new File(own, "HOW-TO-ADD-THE-GAME.txt");
        if (msg == null) { help.delete(); return; }
        String text =
            "Virtua Tennis 3 VR needs your own copy of the arcade game.\n\n" +
            "Last start: " + msg + "\n\n" +
            "Copy the game's vt3_Lindbergh, shader and lib folders (the disk0 folder) so\n" +
            "that the game executable ends up at\n\n" +
            "    /sdcard/VirtuaTennis3/vt3_Lindbergh/vt3_Lindbergh_HD\n\n" +
            "(Internal shared storage > VirtuaTennis3 over USB), and allow the app to access\n" +
            "all files when it asks.\n\n" +
            "The app needs vt3_Lindbergh_HD with SHA-256 " + getString(R.string.elf_sha256).trim() + "\n";
        try (FileOutputStream out = new FileOutputStream(help)) {
            out.write(text.getBytes("UTF-8"));
        } catch (Exception e) {
            Log.w(TAG, "cannot write " + help + ": " + e);
        }
    }
}
