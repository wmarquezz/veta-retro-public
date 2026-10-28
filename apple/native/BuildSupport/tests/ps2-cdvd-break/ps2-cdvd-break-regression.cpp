#include "PS2VM.h"
#include "AppConfig.h"
#include "iop/Iop_Cdvdfsv.h"
#include "MemStream.h"
#include "states/RegisterStateFile.h"
#include <iostream>
#include <map>
#include <stdexcept>
fs::path CAppConfig::GetBasePath() const {auto p=fs::current_path()/"component-private";fs::create_directories(p);return p;}
class FakeSif:public Iop::CSifMan {public:
 std::map<uint32,CSifModule*> modules;unsigned replies=0;
 void RegisterModule(uint32 id,CSifModule*m)override{modules[id]=m;}
 bool IsModuleRegistered(uint32 id)override{return modules.count(id);}
 void UnregisterModule(uint32 id)override{modules.erase(id);}
 void SendPacket(const void*,uint32)override{}
 void SetDmaBuffer(uint32,uint32)override{}
 void SetCmdBuffer(uint32,uint32)override{}
 void SendCallReply(uint32 id,const void*)override{if(id!=0x80000595)throw std::runtime_error("bad reply module");replies++;}
 void GetOtherData(uint32,uint32,uint32)override{}
 void SetModuleResetHandler(const ModuleResetHandler&)override{}
 void SetCustomCommandHandler(const CustomCommandHandler&)override{}
 void ExecuteSifDma(uint32,uint32)override{}
};
class TestVM:public CPS2VM {public:void Prepare(){m_mailBox.SendCall([this](){Reset();},true);}};
int main(){TestVM vm;vm.Initialize();vm.Prepare();int failures=0;auto check=[&](bool ok,const char* name){std::cout<<(ok?"PASS ":"FAIL ")<<name<<std::endl;if(!ok)failures++;};{
 FakeSif sif;Iop::CCdvdfsv f(sif,*vm.m_ee->m_iopBios.GetCdvdman(),vm.m_iop->m_ram);uint32 args[16]={},ret[16]={};
 auto call=[&](uint32 module,uint32 method){std::fill(std::begin(ret),std::end(ret),0xcccccccc);return sif.modules.at(module)->Invoke(method,args,sizeof(args),ret,sizeof(ret),vm.m_ee->m_ram);};
 auto error=[&](){call(0x80000593,4);return ret[0];};auto brk=[&](){call(0x80000593,0x16);};
 check(error()==0,"initial-no-error");brk();check(ret[0]==1,"break-success");check(error()==1,"break-abort-error");check(error()==1,"error-not-consumed");call(0x80000593,0xc);check(error()==1,"status-preserves-error");call(0x8000059c,0);check(error()==1,"disk-ready-preserves-error");
 Framework::CMemStream state;{Framework::CZipArchiveWriter w;f.SaveState(w);w.Write(state);}call(0x80000595,5);check(error()==0,"seek-clears-error");state.Seek(0,Framework::STREAM_SEEK_SET);{Framework::CZipArchiveReader r(state);f.LoadState(r);}check(error()==1,"state-roundtrip-abort");
 Framework::CMemStream oldState;{Framework::CZipArchiveWriter w;auto file=std::make_unique<CRegisterStateFile>("iop_cdvdfsv/state.xml");file->SetRegister32("PendingCommand",0);w.InsertFile(std::move(file));w.Write(oldState);}oldState.Seek(0,Framework::STREAM_SEEK_SET);{Framework::CZipArchiveReader r(oldState);f.LoadState(r);}check(error()==0,"old-state-default-zero");
 brk();check(!call(0x80000595,1),"read-pending");check(error()==0,"read-clears-error");brk();check(sif.replies==1,"break-replies-pending-once");check(error()==1,"pending-abort-error");f.CountTicks(0xffffffff);check(sif.replies==1,"no-late-completion-after-abort");call(0x80000595,1);f.CountTicks(0xffffffff);check(sif.replies==2,"read-after-abort-completes");check(error()==0,"completed-read-no-error");
 brk();args[3]=6;call(0x80000595,9);check(error()==1,"stream-status-preserves-error");args[3]=1;call(0x80000595,9);check(error()==0,"stream-start-clears-error");brk();call(0x80000593,0xc);check(ret[0]==Iop::CCdvdman::CDVD_STATUS_PAUSED,"break-stops-stream");args[3]=0;call(0x80000592,0);check(error()==0,"init-clears-error");
 }vm.Destroy();std::cout<<"FAILURES="<<failures<<std::endl;return failures?1:0;}
