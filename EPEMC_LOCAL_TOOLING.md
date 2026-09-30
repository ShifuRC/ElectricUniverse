# EPEMC local tooling and source handoff

Ramon directs this work; MasterBlaster10 is the manager. Ramon confirmed that the EPEMC corpus is public and authorized updates to ShifuRC/ElectricUniverse. This initial tooling update preserves the existing repository files and history.

## Windows inspection

Run the included script from PowerShell:

```powershell
& .\inspect-mini-pc.ps1
```

It queries hardware, Windows, virtualization, firmware boot mode, WSL, and development-tool availability. It writes MINI_PC_INVENTORY.json and MINI_PC_INVENTORY.md in the adjacent output directory and retains timestamped prior versions. Queries are read-only; only reports are written. Inaccessible information remains unknown, and a missing PATH entry is not treated as proof of an absent installation. Some Windows queries require elevation.

Machine reports, local account/computer identities, and source handoff files are not part of this upload. Review generated reports before sharing them. This script does not install an OS or change accounts, security settings, partitions, or boot settings.

## Project placement directed by Ramon

- EPEMC corpus: public in ElectricUniverse, subject to the established content and source boundaries.
- ResLang: public under MIMS/Bizware, in its separate project area.
- DHSP: private under MIMS/Mimsiness until moved later.
- Other IP: a private Resilient Way repository.

GitHub visibility applies to repositories, not individual folders. Therefore the DHSP folder must reside in a private repository, separate from public MIMS/Bizware content. These are placement rules, not a claim that the other destinations have already been created or populated.

## Source handoff status

The updated local work order and detailed project-bin document were received. The authoritative Citation Tree Project 2025.xlsx and Forward_Engineering_Project_Checklist_50.docx have not been handed into the local project. No corpus migration or citation reconciliation is claimed by this update.

Selected sources must arrive through the agreed handoff. No direct Google Drive synchronization or credential collection is part of this workflow. The local draft manifest is not an approved source manifest. Existing content exclusions remain in force; unrelated or proprietary material is not included merely because a source file is nearby.

Magnus boot testing awaits its artifact, version/provenance, architecture, and boot requirements. A later test should start in a VM and record verifiable results before considering physical media or boot changes.