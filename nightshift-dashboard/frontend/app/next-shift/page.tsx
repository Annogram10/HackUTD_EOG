import { redirect } from "next/navigation";

// Next shift now lives on the Handover page.
export default function NextShift() {
  redirect("/report");
}
