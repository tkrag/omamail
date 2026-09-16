import QtQuick
import QtTest
import "../.." as Omamail
import "../../account/Accounts.js" as Accounts
import "BackendFixture.js" as BackendFixture

Item {
  width: 600
  height: 400
  QtObject {
    id: store
    function updateEntryInline(id, entry) {
    }
  }
  Component {
    id: serviceComponent
    Omamail.Service {
      shell: store
      manifest: ({
          id: "omamail",
          __sourceDir: "/tmp/synthetic"
        })
      property int passwordCalls: 0
      property int oauthCalls: 0
      function signInWithPassword(secret) {
        passwordCalls++;
      }
      function signIn() {
        oauthCalls++;
      }
    }
  }
  TestCase {
    name: "AccountPersistence"
    when: windowShown
    function create() {
      var svc = createTemporaryObject(serviceComponent, parent);
      verify(svc !== null);
      BackendFixture.markReady(svc);
      var list = Accounts.emptyList();
      list = Accounts.add(list, {
        provider: "gmail",
        email: "alias@example.com"
      });
      list = Accounts.add(list, {
        provider: "gmail",
        email: "other@example.com"
      });
      svc.applyAccounts(Accounts.serialize(list));
      compare(svc.lastPersistedIds.length, 2);
      return svc;
    }
    function latestRequest(svc, method) {
      var id = ""
      for (var i = 0; i < svc.backend.children.length; i++) {
        var child = svc.backend.children[i]
        if (!child.written) continue
        var lines = child.written.split("\n")
        for (var j = 0; j < lines.length; j++) {
          if (!lines[j]) continue
          var request = JSON.parse(lines[j])
          if (request.method === method) id = request.id
        }
      }
      return id
    }
    function finishWrite(svc) {
      var id = latestRequest(svc, "accounts.save")
      verify(id !== "")
      svc.backend.receive(JSON.stringify({jsonrpc:"2.0",id:id,result:{revision:"synthetic-revision"}}))
    }
    function test_native_registry_event_reloads_and_coalesces_inflight_read() {
      var svc = create()
      var first = latestRequest(svc, "accounts.read")
      verify(first !== "")
      var revision = new Array(65).join("a")
      svc.backend.receive(JSON.stringify({jsonrpc:"2.0",method:"accounts.changed",params:{revision:revision}}))
      compare(svc.accountsReloadQueued, true)
      svc.backend.receive(JSON.stringify({jsonrpc:"2.0",id:first,result:{registry:svc.accountList,revision:new Array(65).join("b")}}))
      var next = latestRequest(svc, "accounts.read")
      verify(next !== first)
      var changed = Accounts.setLabel(svc.accountList,"alias@example.com","Native change")
      svc.backend.receive(JSON.stringify({jsonrpc:"2.0",id:next,result:{registry:changed,revision:revision}}))
      compare(svc.accountsRevision, revision)
      compare(svc.accountList.accounts[0].label, "Native change")
      compare(svc.accountsReading, false)
    }
    function test_failed_first_read_retries_before_settling_on_a_placeholder() {
      // A fresh service with no BackendFixture auto-responder attached, so
      // the very first accounts.read is answered by hand — this exercises
      // the boot-time race (keyring not yet unlocked, a watched file mid-
      // write) where that first read fails before any real account has ever
      // loaded.
      var svc = createTemporaryObject(serviceComponent, parent);
      verify(svc !== null);
      svc.backendRuntime.requiredVersion = "0.0.0";
      svc.backendRuntime.requiredApiVersion = 1;
      svc.backendRuntime.latestApiVersion = 1;
      svc.backendRuntime.unreleasedMethods = [];
      svc.backendRuntime.executable = "/synthetic/runtime/bin/omamail";
      svc.backendRuntime.state = "ready";
      svc.backend.protocolInfo = { apiVersion: 1, protocol: 1, version: "0.0.0" };
      svc.backend.connected = true;
      compare(svc.accountsLoaded, false);

      var first = latestRequest(svc, "accounts.read");
      verify(first !== "");
      svc.backend.receive(JSON.stringify({jsonrpc:"2.0",id:first,error:{code:-32000,message:"synthetic_failure"}}));
      // Retried, not settled on the empty placeholder yet.
      compare(svc.accountsLoaded, false);
      compare(svc.accountsReadRetries, 1);

      wait(1100);

      var second = latestRequest(svc, "accounts.read");
      verify(second !== first);
      var list = Accounts.emptyList();
      list = Accounts.add(list, { provider: "imap", email: "recovered@example.com" });
      svc.backend.receive(JSON.stringify({jsonrpc:"2.0",id:second,result:{registry:list,revision:"r1"}}));
      compare(svc.accountsLoaded, true);
      compare(svc.accountList.accounts.length, 1);
      compare(svc.accountList.accounts[0].email, "recovered@example.com");
      compare(svc.accountsReadRetries, 0);
    }
    function test_read_failure_settles_on_a_placeholder_once_retries_are_exhausted() {
      // Rather than looping through every retry in real time (racy against
      // the component's own deferred startup call), start one retry short of
      // the limit and confirm the very next failure gives up rather than
      // scheduling another retry.
      var svc = createTemporaryObject(serviceComponent, parent);
      verify(svc !== null);
      svc.backendRuntime.requiredVersion = "0.0.0";
      svc.backendRuntime.requiredApiVersion = 1;
      svc.backendRuntime.latestApiVersion = 1;
      svc.backendRuntime.unreleasedMethods = [];
      svc.backendRuntime.executable = "/synthetic/runtime/bin/omamail";
      svc.backendRuntime.state = "ready";
      svc.backend.protocolInfo = { apiVersion: 1, protocol: 1, version: "0.0.0" };
      svc.backend.connected = true;

      var first = latestRequest(svc, "accounts.read");
      verify(first !== "");
      svc.accountsReadRetries = svc.accountsReadMaxRetries;
      svc.backend.receive(JSON.stringify({jsonrpc:"2.0",id:first,error:{code:-32000,message:"synthetic_failure"}}));
      // Every retry is genuinely exhausted, not a permanently broken account:
      // a still-empty registry settles on the placeholder so onboarding can
      // still be reached, exactly as a real first run always has.
      compare(svc.accountsLoaded, true);
      compare(svc.accountList.accounts.length, 1);
      compare(svc.accountList.accounts[0].pending, true);
    }
    function test_queued_profile_correction_is_saved_after_the_old_write() {
      var svc = create();
      svc.saveAccounts();
      svc.nameAccount(0, "canonical@example.com");
      compare(svc.accountsSaveQueued, true);
      finishWrite(svc);
      verify(svc.accountsWritePayload.indexOf("canonical@example.com") >= 0);
      verify(svc.accountsWritePayload.indexOf("other@example.com") >= 0);
    }
    function test_profile_duplicate_releases_only_its_redundant_row() {
      var svc = create();
      svc.nameAccount(0, "other@example.com");
      compare(svc.accountList.accounts.length, 1);
      compare(Accounts.load(svc.accountsWritePayload).accounts[0].email, "other@example.com");
    }
    function test_first_profile_name_keeps_existing_accounts() {
      var svc = create();
      svc.accountList = Accounts.add(svc.accountList, {
        provider: "gmail",
        email: "",
        pending: true
      });
      svc.nameAccount(2, "new@example.com");
      compare(Accounts.load(svc.accountsWritePayload).accounts.length, 3);
    }
    function test_invalid_profile_name_changes_nothing() {
      var svc = create();
      var before = Accounts.serialize(svc.accountList);
      svc.nameAccount(0, "");
      compare(Accounts.serialize(svc.accountList), before);
      compare(svc.lastPersistedIds, ["alias@example.com", "other@example.com"]);
      compare(svc.accountsWritePayload, "");
    }
    function test_correction_does_not_authorize_an_unrelated_drop() {
      var svc = create();
      svc.nameAccount(0, "canonical@example.com");
      finishWrite(svc);
      svc.accountList = Accounts.remove(svc.accountList, "other@example.com");
      svc.saveAccounts();
      compare(svc.accountsWriting, false, "unrelated omission must not start a writer");
      compare(svc.accountsWritePayload, "");
    }
    function test_provider_identity_change_can_be_saved() {
      var svc = create();
      svc.nameAccount(0, "canonical@example.com");
      compare(svc.accountList.accounts[0].email, "canonical@example.com");
      verify(svc.accountsWritePayload.indexOf("canonical@example.com") >= 0, "profile identity must reach writer");
      finishWrite(svc);
      svc.setAccountLabel("canonical@example.com", "Personal");
      verify(svc.accountsWritePayload.indexOf("Personal") >= 0, "later settings remain writable");
    }
    function test_collision_does_not_dispatch_password_or_oauth() {
      var svc = create();
      var before = Accounts.serialize(svc.accountList);
      compare(svc.configureCurrentAccountAndSignIn({
        email: "other@example.com"
      }, "SYNTHETIC"), false);
      compare(svc.configureCurrentAccountAndSignInOAuth({
        email: "other@example.com"
      }), false);
      wait(0);
      compare(svc.passwordCalls, 0);
      compare(svc.oauthCalls, 0);
      compare(svc.accountsWritePayload, "");
      compare(Accounts.serialize(svc.accountList), before);
    }
  }
}
