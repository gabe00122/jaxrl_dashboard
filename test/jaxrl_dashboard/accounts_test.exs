defmodule JaxrlDashboard.AccountsTest do
  use JaxrlDashboard.DataCase, async: true

  import JaxrlDashboard.AccountsFixtures

  alias JaxrlDashboard.Accounts
  alias JaxrlDashboard.Accounts.{User, UserToken}

  describe "create_user/1" do
    test "creates a user with a generated password that can log in" do
      {:ok, user, password} = Accounts.create_user("alice")

      assert user.username == "alice"
      assert password =~ ~r/^[a-z2-7]{6}(-[a-z2-7]{6}){3}$/
      refute user.hashed_password == password
      assert %User{id: id} = Accounts.get_user_by_username_and_password("alice", password)
      assert id == user.id
    end

    test "rejects duplicate usernames case-insensitively" do
      {:ok, _, _} = Accounts.create_user("alice")
      assert {:error, changeset} = Accounts.create_user("ALICE")
      assert "has already been taken" in errors_on(changeset).username
    end

    test "rejects usernames with spaces or symbols" do
      assert {:error, changeset} = Accounts.create_user("bad name!")
      assert errors_on(changeset).username != []
    end
  end

  describe "get_user_by_username_and_password/2" do
    test "returns nil for a wrong password or unknown user" do
      user = user_fixture()
      refute Accounts.get_user_by_username_and_password(user.username, "wrong password!")
      refute Accounts.get_user_by_username_and_password("nobody", user.password)
    end
  end

  describe "reset_password/1" do
    test "replaces the password and revokes all sessions" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      {:ok, _, new_password} = Accounts.reset_password(user)

      refute Accounts.get_user_by_username_and_password(user.username, user.password)
      assert Accounts.get_user_by_username_and_password(user.username, new_password)
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "session tokens" do
    test "round-trip to the user" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert {%User{id: id}, %DateTime{}} = Accounts.get_user_by_session_token(token)
      assert id == user.id
    end

    test "expire after 14 days" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      Repo.update_all(UserToken, set: [inserted_at: DateTime.add(DateTime.utc_now(), -15, :day)])

      refute Accounts.get_user_by_session_token(token)
    end

    test "are revoked by delete_user_session_token/1 and by deleting the user" do
      user = user_fixture()
      token1 = Accounts.generate_user_session_token(user)
      token2 = Accounts.generate_user_session_token(user)

      Accounts.delete_user_session_token(token1)
      refute Accounts.get_user_by_session_token(token1)
      assert Accounts.get_user_by_session_token(token2)

      {:ok, _} = Accounts.delete_user(user)
      refute Accounts.get_user_by_session_token(token2)
    end
  end
end
