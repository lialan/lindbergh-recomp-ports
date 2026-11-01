// Ghost Squad Evolution VR for Meta Quest. All of the game runs natively
// (libmain.so, see games/ghostsquadevolution/src/android_main.c); this only
// checks that the player's game files are there and loads the libraries.
//
// The game's files (the vsg_l folder) are looked for, as android_main.c does:
//   /sdcard/Android/data/org.lindbergh.gse.vr/files/vsg_l   (where a build with
//        the game inside unpacks it; adb cannot make folders there)
//   /sdcard/GhostSquadEvolution/vsg_l    (where players copy it; needs
//        all-files access, which the app asks for when it finds no game)
// The release APK holds the game's code translated from one exact vsg
// executable (R.string.vsg_sha256); any other version would not run, so it
// is checked here first. Without a usable game the app writes
// HOW-TO-ADD-THE-GAME.txt into its folder and closes.
package org.lindbergh.gse;

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

public class GhostSquadVR extends SDLActivity {
    private static final String TAG = "GhostSquadVR";
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
            File vsg = new File(path, "vsg_l/vsg");
            File env = new File(path, "vsg_l/env.txt");
            if (!vsg.canRead() || !env.canRead() || !getString(R.string.vsg_sha256).trim().equalsIgnoreCase(sha256(vsg))) {
                String error = "Private game diagnostic refused: app cannot read the staged game/config.";
                Log.e(TAG, error);
                return error;
            }
            Log.i(TAG, "private game verified: " + vsg + ", env sha256 " + sha256(env));
            return null;
        }
        try {   /* a build with the game inside unpacks it itself, after this */
            if (Arrays.asList(getAssets().list("")).contains("vsg_l.files")) return null;
        } catch (Exception e) { }

        File shared = new File(Environment.getExternalStorageDirectory(), "GhostSquadEvolution");
        File vsg = null;
        for (File base : new File[] { own, shared }) {
            File f = base == null ? null : new File(base, "vsg_l/vsg");
            if (f != null && f.canRead()) { vsg = f; break; }
        }
        String msg = null;
        if (vsg == null) {
            if (!Environment.isExternalStorageManager()) {
                msg = "Allow Ghost Squad Evolution VR to access all files, copy your vsg_l folder to " +
                      shared + "/vsg_l, then start it again.";
                askForFileAccess();
            } else {
                msg = "Game files not found: copy your vsg_l folder to " + shared + "/vsg_l";
            }
        } else {
            String want = getString(R.string.vsg_sha256).trim();
            String have = sha256(vsg);
            Log.i(TAG, "game: " + vsg + ", vsg " + have);
            if (!want.isEmpty() && !want.equalsIgnoreCase(have)) {
                msg = "This vsg_l is a different version of the game (vsg " + have.substring(0, 12) +
                      "), the app needs vsg " + want.substring(0, 12) + ".";
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
            "Ghost Squad Evolution VR needs your own copy of the arcade game.\n\n" +
            "Last start: " + msg + "\n\n" +
            "Copy the game's whole vsg_l folder (the one with the vsg file in it) so that the\n" +
            "game executable ends up at\n\n" +
            "    /sdcard/GhostSquadEvolution/vsg_l/vsg\n\n" +
            "(Internal shared storage > GhostSquadEvolution > vsg_l over USB), and allow the app\n" +
            "to access all files when it asks.\n\n" +
            "The app needs vsg with SHA-256 " + getString(R.string.vsg_sha256).trim() + "\n";
        try (FileOutputStream out = new FileOutputStream(help)) {
            out.write(text.getBytes("UTF-8"));
        } catch (Exception e) {
            Log.w(TAG, "cannot write " + help + ": " + e);
        }
    }
}
