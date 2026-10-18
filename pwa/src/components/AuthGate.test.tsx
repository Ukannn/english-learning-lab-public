import { useEffect } from "react";
import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
const mocks=vi.hoisted(()=>({getSession:vi.fn(),signIn:vi.fn(),reset:vi.fn(),updateUser:vi.fn(),signOut:vi.fn(),config:true,callback:null as null|((event:string,session:unknown)=>void)}));
vi.mock("../lib/api",()=>({getSession:mocks.getSession,get hasSupabaseConfig(){return mocks.config;},supabase:{auth:{signInWithPassword:mocks.signIn,resetPasswordForEmail:mocks.reset,updateUser:mocks.updateUser,signOut:mocks.signOut,onAuthStateChange:(fn:(event:string,session:unknown)=>void)=>{mocks.callback=fn;return{data:{subscription:{unsubscribe:vi.fn()}}};}}}}));
vi.mock("../lib/recovery",()=>({clearAllRecovery:vi.fn(async()=>undefined),waitForRecoveryCleanup:vi.fn(async()=>undefined)}));
import { AuthGate } from "./AuthGate";
import { PasswordForm } from "./PasswordForm";
import { waitForRecoveryCleanup } from "../lib/recovery";
afterEach(cleanup);beforeEach(()=>{vi.clearAllMocks();vi.mocked(waitForRecoveryCleanup).mockResolvedValue(undefined);mocks.config=true;mocks.getSession.mockResolvedValue(null);mocks.reset.mockResolvedValue({error:null});mocks.updateUser.mockResolvedValue({error:null});mocks.signOut.mockResolvedValue({error:null});history.replaceState(null,"","/");});
describe("Authentication",()=>{
 it("does not remount private content when an old session restoration completes after logout",async()=>{
  let restore!: (session:unknown)=>void;
  mocks.getSession.mockReturnValue(new Promise(resolve=>{restore=resolve;}));
  render(<AuthGate demo={false}><p>Private content</p></AuthGate>);
  act(()=>mocks.callback?.("SIGNED_OUT",null));
  await act(async()=>restore({user:{id:"owner",user_metadata:{password_set:true}}}));
  expect(screen.queryByText("Private content")).toBeNull();
  expect(screen.getByRole("button",{name:"登录"})).toBeTruthy();
 });
 it("waits for old recovery deletion before mounting a new authenticated workspace",async()=>{
  let cleared!: ()=>void;
  vi.mocked(waitForRecoveryCleanup).mockReturnValue(new Promise(resolve=>{cleared=resolve;}));
  mocks.getSession.mockResolvedValue({user:{id:"owner",user_metadata:{password_set:true}}});
  render(<AuthGate demo={false}><p>Private content</p></AuthGate>);
  await waitFor(()=>expect(waitForRecoveryCleanup).toHaveBeenCalled());
  expect(screen.queryByText("Private content")).toBeNull();
  await act(async()=>cleared());
  expect(await screen.findByText("Private content")).toBeTruthy();
 });
 it("offers a working cleanup retry while keeping failed cleanup out of private content",async()=>{
  vi.mocked(waitForRecoveryCleanup).mockRejectedValueOnce(new Error("storage blocked"));
  mocks.getSession.mockResolvedValue({user:{id:"owner",user_metadata:{password_set:true}}});
  const user=userEvent.setup();render(<AuthGate demo={false}><p>Private content</p></AuthGate>);
  await user.click(await screen.findByRole("button",{name:"重试清除本机记录"}));
  expect(await screen.findByText("Private content")).toBeTruthy();
 });
 it("fails closed when configuration is missing",()=>{mocks.config=false;render(<AuthGate demo={false}><p>Private content</p></AuthGate>);expect(screen.getByRole("alert").textContent).toContain("暂不可用");expect(screen.queryByText("Private content")).toBeNull();});
 it("mounts learning content only after login and supports password recovery email",async()=>{
  const mounted=vi.fn();function Child(){useEffect(mounted,[]);return<p>Private content</p>;}
  const user=userEvent.setup();mocks.signIn.mockImplementation(async()=>{mocks.callback?.("SIGNED_IN",{user:{id:"owner",user_metadata:{password_set:true}}});return{error:null};});render(<AuthGate demo={false}><Child/></AuthGate>);
  await screen.findByRole("button",{name:"登录"});expect(mounted).not.toHaveBeenCalled();await user.type(screen.getByLabelText("邮箱"),"owner@example.invalid");await user.click(screen.getByRole("button",{name:"忘记密码"}));expect(mocks.reset).toHaveBeenCalledWith("owner@example.invalid",{redirectTo:"http://localhost:3000/?recovery=1"});await user.type(screen.getByLabelText("密码"),"test-only-password");await user.click(screen.getByRole("button",{name:"登录"}));await screen.findByText("Private content");expect(mounted).toHaveBeenCalledTimes(1);
 });
 it("offers a concrete re-login action when secure password change requires reauthentication",async()=>{
  mocks.updateUser.mockResolvedValue({error:Object.assign(new Error("reauthentication needed"),{code:"reauthentication_needed"})});const user=userEvent.setup();render(<PasswordForm/>);await user.type(screen.getByLabelText("新密码"),"Example-pass-123");await user.type(screen.getByLabelText("确认新密码"),"Example-pass-123");await user.click(screen.getByRole("button",{name:"保存新密码"}));await user.click(await screen.findByRole("button",{name:"重新登录后修改"}));expect(mocks.signOut).toHaveBeenCalledTimes(1);expect(screen.queryByText("密码已更新。")).toBeNull();
 });
 it("requires matching new passwords and reports success only after update",async()=>{
  const user=userEvent.setup();render(<PasswordForm/>);await user.type(screen.getByLabelText("新密码"),"Example-pass-123");await user.type(screen.getByLabelText("确认新密码"),"different-pass");await user.click(screen.getByRole("button",{name:"保存新密码"}));expect(mocks.updateUser).not.toHaveBeenCalled();expect(screen.getByRole("alert").textContent).toContain("不一致");await user.clear(screen.getByLabelText("确认新密码"));await user.type(screen.getByLabelText("确认新密码"),"Example-pass-123");await user.click(screen.getByRole("button",{name:"保存新密码"}));await waitFor(()=>expect(mocks.updateUser).toHaveBeenCalledWith({password:"Example-pass-123",data:{password_set:true}}));expect(screen.getByRole("status").textContent).toContain("已更新");
 });
});
